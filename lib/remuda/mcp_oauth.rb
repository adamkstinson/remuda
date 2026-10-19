# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module Remuda
  # OAuth MCP servers, handled on the host like a ${VAR} header.
  #
  # The human connects once with pi-mcp-adapter (`/mcp-auth <server>`), with
  # settings.oauthCredentialStore "encrypted-file". The adapter writes its
  # store under the agent's Pi dir, encrypted with PI_MCP_ADAPTER_OAUTH_FILE_KEY
  # from the agent .env. Remuda reads that same store, refreshes the access
  # token when it is close to expiry, writes it back in the adapter's format,
  # and hands out an Authorization header. The box never sees the key or the
  # token: its copy of the server points at the forwarder with auth disabled.
  module McpOAuth
    KEY_VAR = "PI_MCP_ADAPTER_OAUTH_FILE_KEY"
    AAD_CONTEXT = "pi-mcp-adapter.oauth.encrypted-file.v1"
    STORE = File.join(".pi", "agent", "mcp-oauth-encrypted")
    REFRESH_SKEW = 300
    HTTP_TIMEOUT = 15

    class Unavailable < StandardError; end

    module_function

    # An OAuth server is one the config says is OAuth, or one with stored
    # adapter credentials and nothing else declaring its auth.
    def oauth?(agent_dir, name, spec)
      return false unless spec.is_a?(Hash)
      return true if spec["auth"] == "oauth"
      return false if spec.key?("auth") || spec.key?("bearerToken") || spec.key?("bearerTokenEnv")
      return false if spec["headers"].is_a?(Hash) && !spec["headers"].empty?

      File.file?(path(agent_dir, name))
    end

    def account(name)
      "sha256-#{Digest::SHA256.hexdigest(name.to_s)}"
    end

    def path(agent_dir, name)
      File.join(File.expand_path(agent_dir), STORE, account(name), "credentials.json")
    end

    def headers(agent_dir, name, spec, now: Time.now)
      { "Authorization" => "Bearer #{access_token(agent_dir, name, spec, now: now)}" }
    end

    def access_token(agent_dir, name, spec, now: Time.now)
      with_lock(agent_dir, name) do
        entry = read(agent_dir, name)
        raise Unavailable, "#{name} is not connected: run `/mcp-auth #{name}` in pi for this agent" if entry.nil?

        tokens = entry["tokens"].is_a?(Hash) ? entry["tokens"] : {}
        if tokens["accessToken"].to_s.empty? || expiring?(tokens, now)
          tokens = refresh(agent_dir, name, entry, spec, now)
          write(agent_dir, name, entry.merge("tokens" => tokens))
        end
        tokens["accessToken"]
      end
    end

    def read(agent_dir, name)
      file = path(agent_dir, name)
      return nil unless File.file?(file)

      envelope = JSON.parse(File.read(file))
      unless envelope["version"] == 1 && envelope["algorithm"] == "aes-256-gcm"
        raise Unavailable, "unsupported OAuth credential envelope at #{file}"
      end

      cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key = key!(agent_dir)
      cipher.iv = Base64.strict_decode64(envelope["iv"])
      cipher.auth_tag = Base64.strict_decode64(envelope["tag"])
      cipher.auth_data = "#{AAD_CONTEXT}\0#{account(name)}"
      plain = cipher.update(Base64.strict_decode64(envelope["ciphertext"])) + cipher.final
      JSON.parse(plain.force_encoding(Encoding::UTF_8))
    rescue OpenSSL::Cipher::CipherError, ArgumentError, JSON::ParserError => e
      raise Unavailable, "cannot read #{name} OAuth credentials (#{e.class}); check #{KEY_VAR} or reconnect with `/mcp-auth #{name}`"
    end

    def write(agent_dir, name, entry)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key = key!(agent_dir)
      iv = SecureRandom.random_bytes(12)
      cipher.iv = iv
      cipher.auth_data = "#{AAD_CONTEXT}\0#{account(name)}"
      ciphertext = cipher.update(JSON.generate(entry)) + cipher.final
      envelope = JSON.generate(
        "version" => 1, "algorithm" => "aes-256-gcm",
        "iv" => Base64.strict_encode64(iv),
        "ciphertext" => Base64.strict_encode64(ciphertext),
        "tag" => Base64.strict_encode64(cipher.auth_tag)
      )
      file = path(agent_dir, name)
      private_dir(File.dirname(File.dirname(file)))
      private_dir(File.dirname(file))
      tmp = File.join(File.dirname(file), ".credentials-#{SecureRandom.hex(12)}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
        f.write(envelope)
        f.fsync
      end
      File.rename(tmp, file)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end

    def key!(agent_dir)
      encoded = Directory.env_vars(agent_dir)[KEY_VAR].to_s
      raise Unavailable, "#{KEY_VAR} is not set in the agent .env" if encoded.empty?

      key = Base64.strict_decode64(encoded)
      raise Unavailable, "#{KEY_VAR} must be base64 for exactly 32 bytes" unless key.bytesize == 32

      key
    rescue ArgumentError
      raise Unavailable, "#{KEY_VAR} must be base64 for exactly 32 bytes"
    end

    def expiring?(tokens, now)
      expires_at = tokens["expiresAt"]
      expires_at && now.to_i >= expires_at.to_i - REFRESH_SKEW
    end

    def refresh(agent_dir, name, entry, spec, now)
      tokens = entry["tokens"] || {}
      refresh_token = tokens["refreshToken"].to_s
      raise Unavailable, "#{name} token expired and has no refresh token: run `/mcp-auth #{name}`" if refresh_token.empty?

      client_id, client_secret = client(entry, spec).map { |value| fill(agent_dir, value) }
      raise Unavailable, "#{name} has no OAuth client id: run `/mcp-auth #{name}`" if client_id.to_s.empty?

      form = { "grant_type" => "refresh_token", "refresh_token" => refresh_token, "client_id" => client_id }
      form["client_secret"] = client_secret unless client_secret.to_s.empty?
      response = post_form(token_endpoint(entry["serverUrl"] || spec["url"], spec), form)
      access = response["access_token"].to_s
      raise Unavailable, "#{name} token refresh returned no access token" if access.empty?

      fresh = tokens.merge("accessToken" => access)
      fresh["refreshToken"] = response["refresh_token"] if response["refresh_token"]
      fresh["expiresAt"] = now.to_i + response["expires_in"].to_i if response["expires_in"]
      fresh["scope"] = response["scope"] if response["scope"]
      fresh
    end

    # The client that got the tokens: what the adapter stored, or, for a
    # client pre-registered in .mcp.json, the config's id and secret.
    def client(entry, spec)
      oauth = spec.is_a?(Hash) && spec["oauth"].is_a?(Hash) ? spec["oauth"] : {}
      info = entry["clientInfo"].is_a?(Hash) ? entry["clientInfo"] : {}
      if oauth["clientId"] && (info["configPreRegistered"] || info["clientId"].to_s.empty?)
        return [oauth["clientId"], oauth["clientSecret"]]
      end

      [info["clientId"], info["clientSecret"]]
    end

    # The adapter fills ${VAR} in OAuth client values from its env; Remuda
    # fills them from the agent .env, then the process env, as for headers.
    def fill(agent_dir, value)
      return value unless value.is_a?(String)

      vars = Directory.env_vars(agent_dir)
      value.gsub(Mcp::PLACEHOLDER) { vars[$1] || ENV[$1] || "" }
    end

    # RFC 9728 then RFC 8414 / OIDC discovery, as the adapter does it.
    def token_endpoint(server_url, spec)
      configured = spec.is_a?(Hash) && spec["oauth"].is_a?(Hash) ? spec["oauth"]["authServerMetadataUrl"] : nil
      return get_json(configured).fetch("token_endpoint") if configured

      uri = URI(server_url)
      resource = get_json("#{uri.scheme}://#{uri.host}#{port_suffix(uri)}/.well-known/oauth-protected-resource#{uri.path.chomp("/")}")
      issuer = Array(resource["authorization_servers"]).first.to_s.chomp("/")
      raise Unavailable, "#{server_url} names no authorization server" if issuer.empty?

      %w[oauth-authorization-server openid-configuration].each do |doc|
        meta = get_json("#{issuer}/.well-known/#{doc}")
        return meta["token_endpoint"] if meta["token_endpoint"]
      rescue Unavailable
        next
      end
      raise Unavailable, "no token endpoint for #{issuer}"
    end

    def port_suffix(uri)
      uri.port == uri.default_port ? "" : ":#{uri.port}"
    end

    def get_json(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
        http.get(uri.request_uri, "Accept" => "application/json")
      end
      raise Unavailable, "GET #{url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise Unavailable, "GET #{url}: #{e.class}"
    end

    def post_form(url, form)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
        request = Net::HTTP::Post.new(uri.request_uri, "Accept" => "application/json")
        request.set_form_data(form)
        http.request(request)
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise Unavailable, "token refresh at #{url}: HTTP #{response.code} #{response.body.to_s[0, 200]}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise Unavailable, "token refresh at #{url}: #{e.class}"
    end

    # Serialise refreshes across Remuda processes (channels, tick, console)
    # so two of them do not race one refresh token.
    def with_lock(agent_dir, name)
      dir = File.join(File.expand_path(agent_dir), STORE)
      private_dir(dir)
      File.open(File.join(dir, ".#{account(name)}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def private_dir(dir)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)
    end
  end
end
