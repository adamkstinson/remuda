# frozen_string_literal: true

require "json"

module Remuda
  # What a failed sandboxed pi leaves on its agent step's `error`: the exit
  # code, pi's own error message, the tail of its stderr and the last JSON
  # event it printed. Together they tell a startup crash (stderr, no events),
  # a provider error (errorMessage) and a cutoff (events that stop mid-turn)
  # apart from `remuda console`.
  #
  # Only text pi printed goes in, and every secret the runner knows about
  # (.env values, auth.json keys) is replaced first. Nothing reads the
  # container's env.
  module AgentFailure
    MAX_STDERR_BYTES = 4096
    MAX_EVENT_BYTES = 1024
    MAX_ERROR_BYTES = 6144
    # Shorter .env values (ports, flags, "true") are not secrets and would
    # turn ordinary words into [REDACTED].
    MIN_SECRET_LENGTH = 8
    REDACTED = "[REDACTED]"

    module_function

    def describe(result, agent_dir)
      secrets = secrets_for(agent_dir)
      stderr = redact(result.stderr.to_s, secrets).strip
      lines = ["exit #{result.exit_code}"]
      pi_error = result.pi_error.to_s.strip
      lines << "pi error: #{tail(redact(pi_error, secrets), MAX_EVENT_BYTES)}" unless pi_error.empty?
      lines << (stderr.empty? ? "stderr: (empty)" : "stderr:\n#{tail(stderr, MAX_STDERR_BYTES)}")
      lines << if result.last_event
        "last event: #{head(redact(JSON.generate(result.last_event), secrets), MAX_EVENT_BYTES)}"
      else
        "last event: (none)"
      end
      head(lines.join("\n"), MAX_ERROR_BYTES)
    end

    # The step's stored text goes through the same filter: a provider error
    # pi echoes as its output can quote the key it was given.
    def scrub(text, agent_dir)
      return text if text.nil?

      redact(text.to_s, secrets_for(agent_dir))
    end

    def secrets_for(agent_dir)
      values = Directory.env_vars(agent_dir).values
      auth_files(agent_dir).each { |path| values.concat(auth_values(path)) }
      values.map(&:to_s).select { |v| v.length >= MIN_SECRET_LENGTH }.uniq.sort_by { |v| -v.length }
    end

    def redact(text, secrets)
      secrets.reduce(text) { |out, secret| out.gsub(secret, REDACTED) }
    end

    def auth_files(agent_dir)
      root = File.expand_path(agent_dir)
      [File.join(root, ".pi", "agent", "auth.json"), File.join(root, ".pi", "auth.json"), ENV["REMUDA_PI_AUTH"]]
        .compact.reject(&:empty?).select { |path| File.file?(path) }
    end

    # Every string in the file: keys, refresh tokens, whatever shape a
    # provider's entry has.
    def auth_values(path)
      strings(JSON.parse(File.read(path)))
    rescue JSON::ParserError, SystemCallError
      []
    end

    def strings(node)
      case node
      when Hash then node.values.flat_map { |v| strings(v) }
      when Array then node.flat_map { |v| strings(v) }
      when String then [node]
      else []
      end
    end

    def tail(text, max)
      bytes = text.b
      return text if bytes.bytesize <= max

      "…" + bytes[-max..].force_encoding("UTF-8").scrub("")
    end

    def head(text, max)
      bytes = text.b
      return text if bytes.bytesize <= max

      bytes[0, max - 3].force_encoding("UTF-8").scrub("") + "…"
    end
  end
end
