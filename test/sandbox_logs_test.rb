# frozen_string_literal: true

require "test_helper"
require "remuda"

class SandboxLogsTest < Minitest::Test
  def test_utf8_split_across_docker_frames_is_reassembled
    text = "Hey. What’s up?"
    bytes = text.encode("UTF-8").b
    split = bytes.index("\xE2".b)
    refute_nil split, "expected a 3-byte UTF-8 apostrophe"

    raw = docker_frame(bytes[0, split + 1]) + docker_frame(bytes[split + 1..])
    decoded = Remuda::Sandbox.send(:decode_logs, raw)

    assert_equal text, decoded
    refute_includes decoded, "\uFFFD"
  end

  def test_emoji_split_across_docker_frames_is_reassembled
    text = "Hey 👋 Ops"
    bytes = text.encode("UTF-8").b
    split = bytes.index("\xF0".b)
    refute_nil split

    raw = docker_frame(bytes[0, split + 2]) + docker_frame(bytes[split + 2..])
    decoded = Remuda::Sandbox.send(:decode_logs, raw)

    assert_equal text, decoded
    refute_includes decoded, "\uFFFD"
  end

  private

  def docker_frame(payload, stream: 1)
    payload = payload.to_s.b
    [stream, 0, 0, 0, payload.bytesize].pack("C4N") + payload
  end
end
