# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "socket"
require "uri"

# Microsoft's side of a Teams bot, on a local port: the Entra token endpoint
# and the Bot Connector's /v3/conversations API. Records every request.
class FakeBotConnector
  attr_reader :port, :requests, :token_requests

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @token_requests = 0
    @next_id = 0
    @accept = Thread.new { accept_loop }
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  def close
    @server.close
    @accept.kill
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      Thread.new(client) { |socket| serve(socket) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(socket)
    method, target, = socket.gets.to_s.split(" ")
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase.strip] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i)
    if target.end_with?("/oauth2/v2.0/token")
      @token_requests += 1
      form = URI.decode_www_form(body).to_h
      reply(socket, { "access_token" => "token-#{form["client_id"]}-#{@token_requests}", "expires_in" => 3600 })
    else
      @next_id += 1
      @requests << { method: method, path: target, authorization: headers["authorization"], body: JSON.parse(body) }
      reply(socket, { "id" => "sent-#{@next_id}" })
    end
  ensure
    socket.close
  end

  def reply(socket, data)
    json = JSON.generate(data)
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{json}")
  end
end

# Signs Bot Framework-shaped JWTs with a key the test controls, and serves
# the matching OpenID metadata + JWKS through a fetch lambda.
class FakeBotFrameworkKeys
  OPENID = "https://login.example/openid"
  JWKS = "https://login.example/jwks"

  attr_reader :key, :kid
  attr_accessor :fetches

  def initialize(kid: "key-1", endorsements: ["msteams"])
    @key = OpenSSL::PKey::RSA.generate(2048)
    @kid = kid
    @endorsements = endorsements
    @fetches = 0
  end

  def jwk
    {
      "kty" => "RSA", "use" => "sig", "kid" => @kid,
      "n" => b64(@key.n.to_s(2)), "e" => b64(@key.e.to_s(2)),
      "endorsements" => @endorsements
    }.compact
  end

  def fetch
    lambda do |url|
      @fetches += 1
      url == OPENID ? { "jwks_uri" => JWKS } : { "keys" => [jwk] }
    end
  end

  def token(claims = {}, key: @key, kid: @kid, alg: "RS256")
    header = b64(JSON.generate("alg" => alg, "typ" => "JWT", "kid" => kid))
    payload = b64(JSON.generate(claims))
    signature = alg == "none" ? "" : b64(key.sign("SHA256", "#{header}.#{payload}"))
    "#{header}.#{payload}.#{signature}"
  end

  def claims(app_id:, service_url:, now: Time.now.to_i)
    {
      "iss" => "https://api.botframework.com", "aud" => app_id,
      "exp" => now + 3600, "nbf" => now - 60, "serviceurl" => service_url
    }
  end

  private

  def b64(data)
    Base64.urlsafe_encode64(data, padding: false)
  end
end
