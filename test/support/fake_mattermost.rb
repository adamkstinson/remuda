# frozen_string_literal: true

require "digest/sha1"
require "json"
require "socket"

# A Mattermost stand-in on a local port: the REST calls the adapter makes, and
# a websocket that sends hello and then whatever the test pushes. Server frames
# go out unmasked; client frames arrive masked, per RFC 6455.
class FakeMattermost
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  BOT = { "id" => "bot-id", "username" => "ops", "is_bot" => true }.freeze

  attr_reader :port, :posts, :typing, :uploads, :client_frames, :upgrade_headers, :requests
  attr_accessor :token, :channel_posts

  def initialize(token: "tok")
    @token = token
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @posts = Queue.new
    @typing = Queue.new
    @uploads = Queue.new
    @files = {}
    @client_frames = Queue.new
    @requests = []
    @sockets = Queue.new
    @channel_posts = {}
    @threads = []
    @accept = Thread.new { accept_loop }
  end

  def add_file(id:, name:, data:, mime_type: "image/jpeg")
    payload = data.to_s.b
    @files[id] = {
      "info" => { "id" => id, "name" => name, "mime_type" => mime_type, "size" => payload.bytesize },
      "data" => payload
    }
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  # The live websocket once the adapter connects (waits up to timeout).
  def socket(timeout: 5)
    @current = Timeout.timeout(timeout) { @sockets.pop }
  end

  def push(event)
    frame(@current || socket, 0x1, JSON.generate(event))
  end

  def push_raw(opcode, payload)
    frame(@current || socket, opcode, payload)
  end

  def drop!
    @current&.close
    @current = nil
  end

  def close
    @server.close
    @threads.each(&:kill)
    @accept.kill
  end

  def self.posted(id:, message:, channel_id: "ch-1", channel_type: "O", user_id: "u-adam",
                  sender: "@adam", root_id: "", mentions: nil, followers: nil, props: {}, type: "",
                  create_at: (Time.now.to_f * 1000).to_i, file_ids: [], files: nil)
    post = {
      "id" => id, "channel_id" => channel_id, "user_id" => user_id, "root_id" => root_id,
      "message" => message, "type" => type, "props" => props, "create_at" => create_at,
      "file_ids" => file_ids
    }
    post["metadata"] = { "files" => files } if files
    data = {
      "channel_type" => channel_type,
      "sender_name" => sender,
      "post" => JSON.generate(post)
    }
    data["mentions"] = JSON.generate(mentions) if mentions
    data["followers"] = JSON.generate(followers) if followers
    { "event" => "posted", "data" => data, "broadcast" => {}, "seq" => 1 }
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      @threads << Thread.new { serve(client) }
    rescue IOError, Errno::EBADF
      break
    end
  end

  def serve(client)
    head = +""
    head << client.readpartial(4096) until head.include?("\r\n\r\n")
    header_part, body = head.split("\r\n\r\n", 2)
    request_line, *lines = header_part.split("\r\n")
    headers = lines.to_h { |line| k, v = line.split(":", 2); [k.strip.downcase, v.to_s.strip] }
    verb, path = request_line.split(" ")
    @requests << [verb, path]

    if headers["upgrade"].to_s.downcase == "websocket"
      upgrade(client, headers)
    else
      length = headers["content-length"].to_i
      body = body.to_s
      body << client.read(length - body.bytesize) while body.bytesize < length
      respond(client, verb, path, headers, body)
    end
  rescue IOError, SystemCallError
    nil
  end

  def respond(client, verb, path, headers, body)
    unless headers["authorization"] == "Bearer #{@token}"
      return reply(client, 401, { "message" => "Invalid or expired session" })
    end

    case [verb, path]
    in ["GET", "/api/v4/users/me"] then reply(client, 200, BOT)
    in ["GET", "/api/v4/users/me/teams"] then reply(client, 200, [{ "id" => "team-1" }])
    in ["GET", "/api/v4/users/me/teams/team-1/channels"]
      reply(client, 200, @channel_posts.keys.map { |id| { "id" => id, "type" => "O" } })
    in ["GET", %r{\A/api/v4/channels/([^/]+)/posts\?since=}]
      posts = @channel_posts.fetch(path[%r{channels/([^/]+)/}, 1], [])
      reply(client, 200, { "order" => posts.map { _1["id"] }, "posts" => posts.to_h { [_1["id"], _1] } })
    in ["GET", %r{\A/api/v4/users/([^/]+)\z}] then reply(client, 200, { "id" => path.split("/").last, "username" => "adam" })
    in ["POST", "/api/v4/posts"]
      post = JSON.parse(body)
      @posts << post
      @post_count = (@post_count || 0) + 1
      reply(client, 201, post.merge("id" => "new-#{@post_count}"))
    in ["POST", "/api/v4/users/me/typing"]
      @typing << JSON.parse(body)
      reply(client, 200, { "status" => "ok" })
    in ["GET", %r{\A/api/v4/files/([^/]+)/info\z}]
      file = @files[path[%r{files/([^/]+)/info}, 1]]
      file ? reply(client, 200, file["info"]) : reply(client, 404, { "message" => "file not found" })
    in ["GET", %r{\A/api/v4/files/([^/]+)\z}]
      file = @files[path.split("/").last]
      file ? reply_raw(client, 200, file["data"]) : reply(client, 404, { "message" => "file not found" })
    in ["POST", "/api/v4/files"]
      uploaded = parse_multipart(headers, body)
      infos = uploaded.map do |part|
        @file_count = (@file_count || 0) + 1
        id = "up-#{@file_count}"
        add_file(id: id, name: part["name"], data: part["data"], mime_type: part["mime_type"])
        @uploads << part.merge("id" => id)
        @files[id]["info"]
      end
      reply(client, 201, { "file_infos" => infos, "client_ids" => [] })
    else reply(client, 404, { "message" => "no route #{verb} #{path}" })
    end
  end

  def reply(client, status, payload)
    json = JSON.generate(payload)
    client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
    client.close
  end

  def reply_raw(client, status, payload)
    body = payload.to_s.b
    client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/octet-stream\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n".b + body)
    client.close
  end

  def parse_multipart(headers, body)
    boundary = headers["content-type"].to_s[/boundary=(.+)/, 1]
    return [] if boundary.nil?

    body.split("--#{boundary}").filter_map do |part|
      next if part.strip.empty? || part.strip == "--"

      head, data = part.split("\r\n\r\n", 2)
      next unless head&.include?("filename=") && data

      name = head[/filename="([^"]*)"/, 1]
      mime = head[/Content-Type:\s*(\S+)/i, 1] || "application/octet-stream"
      { "name" => name, "mime_type" => mime, "data" => data.sub(/\r\n\z/, "").b }
    end
  end

  def upgrade(client, headers)
    @upgrade_headers = headers
    accept = [Digest::SHA1.digest(headers["sec-websocket-key"] + GUID)].pack("m0")
    client.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                 "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
    authorized = headers["authorization"] == "Bearer #{@token}"
    frame(client, 0x1, JSON.generate({ "event" => "hello", "data" => {}, "seq" => 0 })) if authorized
    @sockets << client
    read_client_frames(client)
  end

  def read_client_frames(client)
    loop do
      b0, b1 = client.read(2).bytes
      length = b1 & 0x7f
      length = client.read(2).unpack1("n") if length == 126
      length = client.read(8).unpack1("Q>") if length == 127
      mask = client.read(4).bytes
      data = client.read(length).bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*")
      @client_frames << [b0 & 0x0f, data]
      frame(client, 0xA, data) if (b0 & 0x0f) == 0x9
    end
  rescue NoMethodError, IOError, SystemCallError
    nil
  end

  def frame(client, opcode, payload)
    payload = payload.b
    length = payload.bytesize
    header = [0x80 | opcode].pack("C")
    header << if length < 126 then [length].pack("C")
              elsif length < 65_536 then [126, length].pack("Cn")
              else [127, length].pack("CQ>")
              end
    client.write(header + payload)
  end
end
