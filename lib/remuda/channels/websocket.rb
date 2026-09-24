# frozen_string_literal: true

require "digest/sha1"
require "io/wait"
require "openssl"
require "securerandom"
require "socket"
require "uri"

module Remuda
  module Channels
    # Minimal RFC 6455 client, stdlib only: enough for a bot's event stream.
    # Text frames in and out, ping/pong, close. No extensions, no compression.
    class WebSocket
      GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

      OP_CONT = 0x0
      OP_TEXT = 0x1
      OP_BINARY = 0x2
      OP_CLOSE = 0x8
      OP_PING = 0x9
      OP_PONG = 0xA

      class Closed < StandardError; end
      class HandshakeError < StandardError; end

      attr_reader :last_activity

      def initialize(url, headers: {}, connect_timeout: 10)
        @uri = URI(url)
        @headers = headers
        @connect_timeout = connect_timeout
        @write_lock = Mutex.new
        @buffer = String.new(encoding: Encoding::BINARY)
        @message = nil
        @last_activity = now
      end

      def connect
        tcp = Socket.tcp(@uri.host, port, connect_timeout: @connect_timeout)
        @socket = secure? ? tls(tcp) : tcp
        handshake
        self
      rescue StandardError
        close_socket
        raise
      end

      # Next complete text (or binary) message, or nil when timeout seconds
      # pass first. Answers pings on the way. Raises Closed when the peer goes.
      def read_message(timeout: nil)
        deadline = timeout && now + timeout
        loop do
          frame = next_frame(deadline)
          return nil unless frame

          fin, opcode, payload = frame
          case opcode
          when OP_PING then write_frame(OP_PONG, payload)
          when OP_PONG then nil
          when OP_CLOSE
            begin
              write_frame(OP_CLOSE, payload.byteslice(0, 2).to_s)
            rescue StandardError
              nil
            end
            close_socket
            raise Closed, "closed by peer"
          when OP_TEXT, OP_BINARY
            @message = [opcode, payload]
            return finish_message if fin
          when OP_CONT
            raise Closed, "continuation without a message" unless @message

            @message[1] << payload
            return finish_message if fin
          end
        end
      end

      def send_text(text)
        write_frame(OP_TEXT, text.to_s)
      end

      def ping(payload = "")
        write_frame(OP_PING, payload)
      end

      def close
        return unless @socket

        begin
          write_frame(OP_CLOSE, [1000].pack("n"))
        rescue StandardError
          nil
        end
        close_socket
      end

      def closed?
        @socket.nil?
      end

      private

      def secure?
        %w[wss https].include?(@uri.scheme)
      end

      def port
        @uri.port || (secure? ? 443 : 80)
      end

      def tls(tcp)
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.hostname = @uri.host
        ssl.sync_close = true
        ssl.connect
        ssl.post_connection_check(@uri.host)
        ssl
      end

      def handshake
        key = [SecureRandom.random_bytes(16)].pack("m0")
        path = @uri.path.to_s.empty? ? "/" : @uri.path
        path += "?#{@uri.query}" if @uri.query
        host = @uri.port && @uri.port != (secure? ? 443 : 80) ? "#{@uri.host}:#{@uri.port}" : @uri.host

        lines = [
          "GET #{path} HTTP/1.1",
          "Host: #{host}",
          "Upgrade: websocket",
          "Connection: Upgrade",
          "Sec-WebSocket-Key: #{key}",
          "Sec-WebSocket-Version: 13"
        ]
        @headers.each { |name, value| lines << "#{name}: #{value}" }
        @write_lock.synchronize { @socket.write("#{lines.join("\r\n")}\r\n\r\n") }

        deadline = now + @connect_timeout
        until (split = @buffer.index("\r\n\r\n"))
          raise HandshakeError, "no handshake response within #{@connect_timeout}s" unless fill(@buffer.bytesize + 1, deadline)
          raise HandshakeError, "handshake response too large" if @buffer.bytesize > 16_384
        end

        head = @buffer.byteslice(0, split).force_encoding(Encoding::UTF_8)
        @buffer = @buffer.byteslice(split + 4..) || String.new(encoding: Encoding::BINARY)
        status, *header_lines = head.split("\r\n")
        raise HandshakeError, "upgrade refused: #{status}" unless status.to_s.match?(%r{\AHTTP/1\.1 101\b})

        headers = header_lines.to_h do |line|
          name, value = line.split(":", 2)
          [name.to_s.strip.downcase, value.to_s.strip]
        end
        expected = [Digest::SHA1.digest(key + GUID)].pack("m0")
        raise HandshakeError, "bad Sec-WebSocket-Accept" unless headers["sec-websocket-accept"] == expected

        @last_activity = now
      end

      # [fin, opcode, payload] once a whole frame is buffered; nil on timeout.
      # A frame that is only partly in is left in the buffer for the next call.
      def next_frame(deadline)
        return nil unless fill(2, deadline)

        b0 = @buffer.getbyte(0)
        b1 = @buffer.getbyte(1)
        length = b1 & 0x7f
        offset = 2
        if length == 126
          return nil unless fill(4, deadline)

          length = @buffer.byteslice(2, 2).unpack1("n")
          offset = 4
        elsif length == 127
          return nil unless fill(10, deadline)

          length = @buffer.byteslice(2, 8).unpack1("Q>")
          offset = 10
        end

        masked = (b1 & 0x80) != 0
        mask = nil
        if masked
          return nil unless fill(offset + 4, deadline)

          mask = @buffer.byteslice(offset, 4)
          offset += 4
        end
        return nil unless fill(offset + length, deadline)

        payload = @buffer.byteslice(offset, length)
        @buffer = @buffer.byteslice(offset + length..) || String.new(encoding: Encoding::BINARY)
        payload = apply_mask(payload, mask) if mask
        @last_activity = now
        [(b0 & 0x80) != 0, b0 & 0x0f, payload]
      end

      def finish_message
        opcode, payload = @message
        @message = nil
        opcode == OP_TEXT ? payload.force_encoding(Encoding::UTF_8) : payload
      end

      def write_frame(opcode, payload)
        raise Closed, "not connected" unless @socket

        payload = payload.to_s.b
        length = payload.bytesize
        frame = [0x80 | opcode].pack("C")
        frame << if length < 126
                   [0x80 | length].pack("C")
                 elsif length < 65_536
                   [0x80 | 126, length].pack("Cn")
                 else
                   [0x80 | 127, length].pack("CQ>")
                 end
        mask = SecureRandom.random_bytes(4)
        frame << mask << apply_mask(payload, mask)
        @write_lock.synchronize { @socket.write(frame) }
      end

      def apply_mask(data, mask)
        key = mask.bytes
        data.bytes.each_with_index.map { |byte, i| byte ^ key[i % 4] }.pack("C*")
      end

      def fill(size, deadline)
        while @buffer.bytesize < size
          raise Closed, "not connected" unless @socket

          chunk = @socket.read_nonblock(16_384, exception: false)
          case chunk
          when :wait_readable then return false unless wait(deadline, :read)
          when :wait_writable then return false unless wait(deadline, :write)
          when nil
            close_socket
            raise Closed, "connection closed by peer"
          else @buffer << chunk.b
          end
        end
        true
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
        close_socket
        raise Closed, e.message
      end

      def wait(deadline, direction)
        remaining = deadline && deadline - now
        return false if remaining && remaining <= 0

        io = @socket.to_io
        direction == :read ? io.wait_readable(remaining) : io.wait_writable(remaining)
      end

      def close_socket
        @socket&.close
      rescue StandardError
        nil
      ensure
        @socket = nil
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
