# frozen_string_literal: true

require "fileutils"
require "json"

module Remuda
  # Per-agent model provider config. The runner reads the agent .env on the
  # host and writes the agent's Pi auth.json; it never mounts .env into the
  # sandbox.
  module PiAuth
    ENV_TO_PROVIDER = {
      "ANTHROPIC_API_KEY" => "anthropic",
      "ANT_LING_API_KEY" => "ant-ling",
      "AZURE_OPENAI_API_KEY" => "azure-openai-responses",
      "OPENAI_API_KEY" => "openai",
      "DEEPSEEK_API_KEY" => "deepseek",
      "NVIDIA_API_KEY" => "nvidia",
      "GEMINI_API_KEY" => "google",
      "AWS_BEARER_TOKEN_BEDROCK" => "amazon-bedrock",
      "MISTRAL_API_KEY" => "mistral",
      "GROQ_API_KEY" => "groq",
      "CEREBRAS_API_KEY" => "cerebras",
      "XAI_API_KEY" => "xai",
      "OPENROUTER_API_KEY" => "openrouter",
      "AI_GATEWAY_API_KEY" => "vercel-ai-gateway",
      "ZAI_API_KEY" => "zai",
      "OPENCODE_API_KEY" => "opencode",
      "HF_TOKEN" => "huggingface",
      "FIREWORKS_API_KEY" => "fireworks",
      "TOGETHER_API_KEY" => "together",
      "BASETEN_API_KEY" => "baseten",
      "KIMI_API_KEY" => "kimi-coding",
      "MINIMAX_API_KEY" => "minimax",
      "DARKHORSE_API_KEY" => "darkhorse"
    }.freeze

    def self.env_vars(agent_dir)
      Directory.env_vars(agent_dir)
    end

    def self.provider(agent_dir)
      blank_to_nil(env_vars(agent_dir)["PI_PROVIDER"])
    end

    def self.model(agent_dir)
      blank_to_nil(env_vars(agent_dir)["PI_MODEL"])
    end

    # Writes the provider keys named in the agent's .env into
    # <agent>/.pi/agent/auth.json, the Pi user dir the sandbox mounts as
    # PI_CODING_AGENT_DIR. .env owns the providers it names (a rotated key
    # takes effect on the next run); every other entry — a login made inside
    # `remuda` — is kept. Never reads the operator's ~/.pi/agent. Returns
    # whether it wrote.
    def self.sync!(agent_dir)
      wanted = from_env(env_vars(agent_dir))
      return false unless wanted

      path = auth_path(agent_dir)
      current = read_auth(path)
      return false if current.nil?

      merged = current.merge(wanted)
      return false if merged == current

      write_auth(path, merged)
      true
    end

    def self.auth_path(agent_dir)
      File.join(File.expand_path(agent_dir), ".pi", "agent", "auth.json")
    end

    # {} for a missing or empty file; nil for one this code must not touch.
    def self.read_auth(path)
      return {} unless File.file?(path)

      text = File.read(path)
      return {} if text.strip.empty?

      data = JSON.parse(text)
      return data if data.is_a?(Hash)

      warn "remuda: #{path} is not a JSON object; not writing provider keys from .env"
      nil
    rescue JSON::ParserError
      warn "remuda: #{path} is not valid JSON; not writing provider keys from .env"
      nil
    end
    private_class_method :read_auth

    def self.write_auth(path, data)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".auth.json.#{Process.pid}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(JSON.pretty_generate(data))
        f.write("\n")
      end
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
    private_class_method :write_auth

    def self.from_env(vars)
      wanted = blank_to_nil(vars["PI_PROVIDER"])
      creds = {}
      ENV_TO_PROVIDER.each do |env_name, provider|
        key = blank_to_nil(vars[env_name])
        next unless key
        next if wanted && wanted != provider

        creds[provider] = { "type" => "api_key", "key" => key }
      end
      creds.empty? ? nil : creds
    end
    private_class_method :from_env

    def self.blank_to_nil(value)
      return nil if value.nil?

      stripped = value.to_s.strip
      stripped.empty? ? nil : stripped
    end
    private_class_method :blank_to_nil
  end
end
