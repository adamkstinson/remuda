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

  # Pi exits 0 even when the provider refused the call, so the stopReason is
  # the only signal. The assistant may have printed text before it failed.
  ERROR_WITH_TEXT_JSONL = <<~JSONL
    {"type":"session","version":3,"id":"sess-3"}
    {"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Working on it"}]},"stopReason":"error","errorMessage":"xai API error (403): out of credits"}
  JSONL

  def test_assistant_text_from_successful_turn
    parsed = Remuda::PiJsonl.parse(JSONL)
    assert_equal "Hey. Ops here. What do you need?", parsed[:output]
    assert_equal "sess-1", parsed[:session_id]
    assert parsed[:jsonl]
    assert_nil parsed[:error]
    refute parsed[:model_error]
  end

  def test_error_message_when_no_assistant_text
    parsed = Remuda::PiJsonl.parse(ERROR_JSONL)
    assert_equal "OAuth refresh failed for xai", parsed[:output]
    assert_equal "OAuth refresh failed for xai", parsed[:error]
    assert parsed[:jsonl]
    assert parsed[:model_error]
  end

  def test_last_assistant_message_with_stop_reason_error_is_flagged
    parsed = Remuda::PiJsonl.parse(ERROR_WITH_TEXT_JSONL)
    assert_equal "Working on it", parsed[:output]
    assert parsed[:model_error]
    assert_equal "xai API error (403): out of credits", parsed[:error]
  end

  # A run can recover mid-turn; what matters is the last assistant message.
  def test_a_later_successful_assistant_message_clears_the_error
    raw = [
      { "type" => "message_end", "message" => { "role" => "assistant", "content" => [] },
        "stopReason" => "error", "errorMessage" => "transient blip" },
      { "type" => "message_end", "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "recovered" }] },
        "stopReason" => "stop" }
    ].map { |event| JSON.generate(event) }.join("\n")

    parsed = Remuda::PiJsonl.parse(raw)
    refute parsed[:model_error]
    assert_nil parsed[:error]
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
