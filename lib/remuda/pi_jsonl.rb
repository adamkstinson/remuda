# frozen_string_literal: true

require "json"

module Remuda
  # Pi `--mode json` prints one JSON object per line (session, message_end,
  # usage, errors). Channel replies and workflow `result.output` want the
  # assistant's text, not that stream.
  module PiJsonl
    module_function

    def parse(raw)
      raw = raw.to_s
      last_text = nil
      error = nil
      session_id = nil
      usage = nil
      jsonl = false

      raw.each_line do |line|
        line = line.strip
        next if line.empty?
        next unless line.start_with?("{")

        event = JSON.parse(line)
        next unless event.is_a?(Hash)

        jsonl = true if event["type"]
        session_id ||= event["id"] if event["type"] == "session"
        error = event["errorMessage"] if event["errorMessage"].to_s != ""
        usage = event.dig("message", "usage") || event["usage"] || usage

        msg = event["message"]
        next unless msg.is_a?(Hash) && msg["role"] == "assistant"
        next unless %w[message_end turn_end].include?(event["type"])

        texts = Array(msg["content"]).filter_map do |part|
          part["text"] if part.is_a?(Hash) && part["type"] == "text" && part["text"].to_s != ""
        end
        joined = texts.join
        last_text = joined unless joined.empty?
      rescue JSON::ParserError
        next
      end

      output = if jsonl
        last_text.to_s.empty? ? error.to_s : last_text
      else
        raw.strip
      end

      { output: output, session_id: session_id, usage: usage, error: error, jsonl: jsonl }
    end
  end
end
