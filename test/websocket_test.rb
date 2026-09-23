# frozen_string_literal: true

require "test_helper"
require "json"
require "timeout"
require "remuda"
require_relative "support/fake_mattermost"

class WebSocketTest < Minitest::Test
  def setup
    @server = FakeMattermost.new
    @ws = Remuda::Channels::WebSocket.new(
      "ws://127.0.0.1:#{@server.port}/api/v4/websocket",
      headers: { "Authorization" => "Bearer tok" }
    ).connect
    @socket = @server.socket
  end

  def teardown
    @ws.close
    @server.close
  end

  def test_handshake_then_messages_of_every_length_class
    assert_equal "hello", JSON.parse(@ws.read_message(timeout: 2))["event"]
    ["short", "m" * 300, "ü" * 40_000].each do |text|
      @server.push_raw(0x1, text)
      assert_equal text, @ws.read_message(timeout: 2)
    end
  end

  def test_timeout_returns_nil_and_keeps_partial_frames
    @ws.read_message(timeout: 2)
    assert_nil @ws.read_message(timeout: 0.1)

    @socket.write([0x81, 5].pack("CC") + "he")
    assert_nil @ws.read_message(timeout: 0.1)
    @socket.write("llo")
    assert_equal "hello", @ws.read_message(timeout: 1)
  end

  def test_fragments_are_reassembled_around_a_ping
    @ws.read_message(timeout: 2)
    @socket.write([0x01, 3].pack("CC") + "abc")          # text, not final
    @socket.write([0x89, 2].pack("CC") + "pi")           # ping in between
    @socket.write([0x80, 3].pack("CC") + "def")          # final continuation
    assert_equal "abcdef", @ws.read_message(timeout: 2)
    assert_equal [0xA, "pi"], Timeout.timeout(2) { @server.client_frames.pop }
  end

  def test_client_frames_are_masked_text
    @ws.send_text('{"action":"user_typing"}')
    assert_equal [0x1, '{"action":"user_typing"}'], Timeout.timeout(2) { @server.client_frames.pop }
  end

  def test_peer_close_raises_closed
    @ws.read_message(timeout: 2)
    @server.drop!
    assert_raises(Remuda::Channels::WebSocket::Closed) { @ws.read_message(timeout: 2) }
    assert @ws.closed?
  end
end
