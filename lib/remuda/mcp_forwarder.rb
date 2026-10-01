# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "socket"
require "uri"

module Remuda
  # Per-run HTTP reverse proxy that lets the sandbox call MCP servers whose
  # credentials live on the host.
  #
  # The host mcp.json is the declaration. For each server that declares
  # headers, the agent's copy points at this forwarder instead of the real
  # URL and carries no headers; the forwarder adds the declared headers,
  # filled from the agent .env then the process env, on the way out. A server
  # with no headers keeps its URL. The forwarder copies method, path, query,
  # headers, and bodies through and streams both ways. It does not speak MCP.
  #
  # Every path starts with a random per-run token, so a request from anything
  # but the container that got this run's mcp.json is a 404.
  class McpForwarder
    CONTAINER_HOST = "host.docker.internal"
    UPSTREAM_TIMEOUT = 3600
    HOP_BY_HOP = %w[
      connection keep-alive proxy-authenticate proxy-authorization proxy-connection
      te trailer transfer-encoding upgrade host content-length
    ].freeze
    PLACEHOLDER = /\{\{(\w+)\}\}/

    Route = Data.define(:name, :upstream, :headers, :missing)

    # Rewrite the agent's mcp.json for this run and serve it until the block
    # returns. Yields the path of the secret-free copy (nil without mcp.json)
    # and the running forwarder (nil when no server needs one).
    def self.open(agent_dir, tmpdir)
      host_file = File.join(File.expand_path(agent_dir), "mcp.json")
      return yield(nil, nil) unless File.file?(host_file)

      config = JSON.parse(File.read(host_file))
      token = SecureRandom.hex(16)
      forwarder = new({}, token: token, bind: bind_address)
      forwarder.start
      begin
        agent_config, routes = plan(
          config,
          vars: Directory.env_vars(agent_dir),
          base_url: "http://#{CONTAINER_HOST}:#{forwarder.port}/#{token}"
        )
        forwarder.routes = routes
        path = File.join(tmpdir, "mcp.json")
        File.write(path, JSON.pretty_generate(agent_config))
        File.chmod(0o644, path)
        yield path, (routes.empty? ? nil : forwarder)
      ensure
        forwarder.stop
      end
    end

    # Pure: the agent's copy of mcp.json and the forwarder's route table.
    def self.plan(config, vars:, base_url:, env: ENV)
      config = config.is_a?(Hash) ? config : {}
      routes = {}
      servers = (config["mcpServers"] || {}).to_h do |name, spec|
        headers = spec.is_a?(Hash) ? spec["headers"] : nil
        url = spec.is_a?(Hash) ? Mcp.resolve_url(spec) : nil
        if !headers.is_a?(Hash) || headers.empty? || url.nil?
          next [name, spec] unless url

          next [name, spec.except("tailscale_url").merge("url" => url)]
        end

        filled, missing = fill(headers, vars, env)
        routes[name] = Route.new(name: name, upstream: Mcp.host_url(url), headers: filled, missing: missing)
        [name, spec.except("headers", "tailscale_url").merge("url" => "#{base_url}/#{name}")]
      end
      [config.merge("mcpServers" => servers), routes]
    end

    # Same rule as Remuda.tool: the agent .env, then the process env. A
    # placeholder with no value is reported, never sent blank.
    def self.fill(headers, vars, env = ENV)
      missing = []
      filled = headers.to_h do |key, value|
        text = value.to_s.gsub(PLACEHOLDER) do
          found = vars[$1] || env[$1]
          missing << $1 if found.nil? || found.empty?
          found.to_s
        end
        [key.to_s, text]
      end
      [filled, missing.uniq]
    end

    # Where the container can reach the host: the Docker bridge gateway (what
    # host.docker.internal resolves to on Linux), or loopback where Docker
    # forwards host.docker.internal itself.
    def self.bind_address
      override = ENV["REMUDA_FORWARDER_BIND"].to_s
      return override unless override.empty?

      gateway = Docker::Network.get("bridge").info.dig("IPAM", "Config", 0, "Gateway").to_s
      return gateway if !gateway.empty? && local_address?(gateway)

      "127.0.0.1"
    rescue StandardError
      "127.0.0.1"
    end

    def self.local_address?(ip)
      Socket.ip_address_list.any? { |addr| addr.ip_address == ip }
    end
    private_class_method :local_address?

    attr_accessor :routes

    def initialize(routes, token:, bind: "127.0.0.1", logger: $stderr)
      @routes = routes
      @token = token
      @bind = bind
      @logger = logger
      @clients = []
      @lock = Mutex.new
    end

    def port
      @server&.addr&.at(1)
    end

    def start
      @server = TCPServer.new(@bind, 0)
      @thread = Thread.new { accept_loop }
      self
    end

    def stop
      @server&.close
      @thread&.join(2)
      @lock.synchronize { @clients.each(&:kill) }
      @server = nil
      nil
    rescue IOError
      nil
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        thread = Thread.new(client) { |socket| serve(socket) }
        @lock.synchronize do
          @clients.reject!(&:stop?)
          @clients << thread
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(socket)
      sent = { head: false }
      method, target, headers = read_head(socket)
      return if method.nil?

      route, rest = resolve(target)
      return respond(socket, 404, "remuda forwarder: no such route\n") if route.nil?
      unless route.missing.empty?
        return respond(socket, 401, "remuda forwarder: #{route.name} needs " \
                                    "#{route.missing.join(", ")}, which is not set on the host\n")
      end

      forward(socket, route, method, rest, headers, sent)
    rescue StandardError => e
      @logger&.puts("remuda forwarder: #{route&.name || "request"} failed: #{e.class}")
      respond(socket, 502, "remuda forwarder: upstream failed (#{e.class})\n") unless sent[:head]
    ensure
      socket.close unless socket.closed?
    end

    def read_head(socket)
      request_line = socket.gets("\r\n")
      return if request_line.nil?

      method, target, = request_line.split(" ", 3)
      headers = []
      while (line = socket.gets("\r\n")) && line != "\r\n"
        key, value = line.split(":", 2)
        headers << [key.strip, value.to_s.strip]
      end
      [method, target, headers]
    end

    def resolve(target)
      path, query = target.to_s.split("?", 2)
      _, token, name, rest = path.split("/", 4)
      return [nil, nil] unless token == @token

      route = @routes[name.to_s]
      return [nil, nil] if route.nil?

      [route, ["/#{rest}".delete_suffix("/"), query]]
    end

    def forward(socket, route, method, (rest, query), headers, sent)
      uri = URI(route.upstream)
      uri.path = "#{uri.path.delete_suffix("/")}#{rest}"
      uri.path = "/" if uri.path.empty?
      uri.query = [uri.query, query].compact.reject(&:empty?).join("&").then { |q| q.empty? ? nil : q }

      # Pass Accept-Encoding through so Net::HTTP leaves the body encoded,
      # matching the Content-Encoding header the client gets.
      init = { "Accept-Encoding" => header(headers, "accept-encoding") || "identity" }
      request = Net::HTTPGenericRequest.new(method, body?(headers), method != "HEAD", uri.request_uri, init)
      headers.each do |key, value|
        next if HOP_BY_HOP.include?(key.downcase)

        request[key] = value
      end
      route.headers.each { |key, value| request[key] = value }
      attach_body(request, socket, headers)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                          read_timeout: UPSTREAM_TIMEOUT) do |http|
        http.request(request) do |response|
          write_head(socket, response)
          sent[:head] = true
          response.read_body do |chunk|
            socket.write(chunk)
            socket.flush
          end
        end
      end
    end

    def body?(headers)
      headers.any? { |key, value| key.casecmp?("content-length") ? value.to_i.positive? : key.casecmp?("transfer-encoding") }
    end

    def attach_body(request, socket, headers)
      length = header(headers, "content-length")
      chunked = header(headers, "transfer-encoding").to_s.downcase.include?("chunked")
      if chunked
        request["Transfer-Encoding"] = "chunked"
        request.body_stream = ChunkedReader.new(socket)
      elsif length.to_i.positive?
        request.content_length = length.to_i
        request.body_stream = LimitedReader.new(socket, length.to_i)
      end
    end

    def header(headers, name)
      headers.find { |key, _| key.casecmp?(name) }&.last
    end

    # The body goes to the client as Net::HTTP decodes it, so the framing
    # is ours: a known length passes through, anything else ends at close.
    def write_head(socket, response)
      lines = ["HTTP/1.1 #{response.code} #{response.message}"]
      response.each_capitalized do |key, value|
        next if HOP_BY_HOP.include?(key.downcase)

        lines << "#{key}: #{value}"
      end
      length = response["Content-Length"]
      lines << "Content-Length: #{length}" if length && response["Transfer-Encoding"].nil?
      lines << "Connection: close"
      socket.write("#{lines.join("\r\n")}\r\n\r\n")
      socket.flush
    end

    def respond(socket, status, body)
      reason = { 401 => "Unauthorized", 404 => "Not Found", 502 => "Bad Gateway" }.fetch(status, "Error")
      socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: text/plain\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    rescue IOError, SystemCallError
      nil
    end

    # Reads exactly length bytes of a request body off the client socket.
    class LimitedReader
      def initialize(io, length)
        @io = io
        @left = length
      end

      def read(size = nil, buffer = nil)
        return (size.nil? || size.zero? ? +"" : nil) if @left <= 0

        size = size.nil? ? @left : [size, @left].min
        data = @io.readpartial(size)
        @left -= data.bytesize
        buffer ? buffer.replace(data) : data
      rescue EOFError
        @left = 0
        nil
      end
    end

    # Decodes a chunked request body off the client socket.
    class ChunkedReader
      def initialize(io)
        @io = io
        @left = 0
        @done = false
      end

      def read(size = nil, buffer = nil)
        return nil if @done

        if @left.zero?
          @left = @io.gets("\r\n").to_s.split(";").first.to_i(16)
          if @left.zero?
            while (line = @io.gets("\r\n")) && line != "\r\n"; end
            @done = true
            return nil
          end
        end
        size = size.nil? ? @left : [size, @left].min
        data = @io.read(size)
        @left -= data.bytesize
        @io.read(2) if @left.zero?
        buffer ? buffer.replace(data) : data
      end
    end
  end
end
