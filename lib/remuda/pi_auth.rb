# frozen_string_literal: true

require "fileutils"
require "json"

module Remuda
  # Per-agent model provider config. The runner reads the agent .env on the
  # host and stages a Pi auth.json; it never mounts .env into the sandbox.
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
      "MINIMAX_API_KEY" => "minimax"
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

    def self.stage(tmpdir, agent_dir)
      source = resolve(agent_dir)
      return nil unless source
      return source[:dir] if source[:dir]

      dir = File.join(tmpdir, "pi-agent")
      FileUtils.mkdir_p(dir)
      File.chmod(0o700, dir)
      dest = File.join(dir, "auth.json")
      if source[:file]
        FileUtils.cp(source[:file], dest)
      else
        File.write(dest, source[:json])
      end
      File.chmod(0o600, dest)
      dir
    end

    def self.resolve(agent_dir)
      override = blank_to_nil(ENV["REMUDA_PI_AUTH"])
      return { file: override } if override && File.file?(override)

      root = File.expand_path(agent_dir)
      agent_pi = File.join(root, ".pi", "agent")
      return { dir: agent_pi } if File.file?(File.join(agent_pi, "auth.json"))

      flat = File.join(root, ".pi", "auth.json")
      return { file: flat } if File.file?(flat)

      synthesized = from_env(env_vars(agent_dir))
      return { json: synthesized } if synthesized

      nil
    end

    def self.from_env(vars)
      wanted = blank_to_nil(vars["PI_PROVIDER"])
      creds = {}
      ENV_TO_PROVIDER.each do |env_name, provider|
        key = blank_to_nil(vars[env_name])
        next unless key
        next if wanted && wanted != provider

        creds[provider] = { "type" => "api_key", "key" => key }
      end
      return nil if creds.empty?

      JSON.pretty_generate(creds)
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
