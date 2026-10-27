# frozen_string_literal: true

require "yaml"

module Remuda
  # The model fallback an agent declares in .remuda/model.yml:
  #
  #   fallback:
  #     provider: anthropic
  #     model: claude-sonnet-4-5
  #
  # When a run's primary provider/model ends in a provider error (#70),
  # Remuda.agent retries once on this fallback (#71). Either key may be
  # omitted; Pi resolves whatever the retry leaves out. No block, or an
  # empty one, means no retry.
  module ModelConfig
    FILE = File.join(".remuda", "model.yml")

    def self.fallback(agent_dir)
      path = File.join(File.expand_path(agent_dir), FILE)
      return nil unless File.file?(path)

      config = YAML.safe_load(File.read(path))
      return nil if config.nil?

      raise ArgumentError, "#{path}: expected a mapping" unless config.is_a?(Hash)

      spec = config["fallback"]
      return nil if spec.nil?

      raise ArgumentError, "#{path}: fallback: expected a mapping" unless spec.is_a?(Hash)

      provider = spec["provider"].to_s.strip
      model = spec["model"].to_s.strip
      return nil if provider.empty? && model.empty?

      { provider: provider.empty? ? nil : provider, model: model.empty? ? nil : model }
    end
  end
end
