# frozen_string_literal: true

require "test_helper"
require "remuda"

class PiJsonlTest < Minitest::Test
  JSONL = <<~JSONL
    {"type":"session","version":3,"id":"sess-1"}
    {"type":"agent_start"}
    {"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"@ops hey"}]}}
    {"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Preparing a reply."},{"type":"text","text":"Hey. Ops here. What do you need?"}]},"stopReason":"stop"}
    {"type":"agent_settled"}
  JSONL

  ERROR_JSONL = <<~JSONL
    {"type":"session","version":3,"id":"sess-2"}
    {"type":"message_end","message":{"role":"assistant","content":[]},"stopReason":"error","errorMessage":"OAuth refresh failed for xai"}
  JSONL

  def test_assistant_text_from_successful_turn
    parsed = Remuda::PiJsonl.parse(JSONL)
    assert_equal "Hey. Ops here. What do you need?", parsed[:output]
    assert_equal "sess-1", parsed[:session_id]
    assert parsed[:jsonl]
    assert_nil parsed[:error]
  end

  def test_error_message_when_no_assistant_text
    parsed = Remuda::PiJsonl.parse(ERROR_JSONL)
    assert_equal "OAuth refresh failed for xai", parsed[:output]
    assert_equal "OAuth refresh failed for xai", parsed[:error]
    assert parsed[:jsonl]
  end

  def test_plain_text_passes_through
    parsed = Remuda::PiJsonl.parse("pong\n")
    assert_equal "pong", parsed[:output]
    refute parsed[:jsonl]
  end

  def test_does_not_return_the_raw_stream
    parsed = Remuda::PiJsonl.parse(JSONL)
    refute_includes parsed[:output], '"type":"session"'
  end
end
