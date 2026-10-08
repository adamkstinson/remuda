# frozen_string_literal: true

require "yaml"

module Remuda
  # Extra bind mounts for the sandbox, declared in .remuda/mounts.yml:
  #
  #   core: ../../Products/core        # read-write
  #   docs: ../../Docs:ro              # read-only
  #   index.yml: ../../index.yml:ro    # a file works too
  #
  # Each key is mounted at /work/<key>. Paths are relative to the agent
  # directory. A path that does not exist on the host is an error, because
  # Docker would create it root-owned.
  module Mounts
    ROOT = "/work"

    def self.for(agent_dir)
      agent_dir = File.expand_path(agent_dir)
      path = File.join(agent_dir, ".remuda", "mounts.yml")
      return [] unless File.file?(path)

      entries = YAML.safe_load(File.read(path)) || {}
      raise ArgumentError, "#{path}: expected a mapping of name: path" unless entries.is_a?(Hash)

      entries.map do |name, spec|
        name = name.to_s
        raise ArgumentError, "#{path}: bad mount name #{name.inspect}" if name.empty? || name.include?("/") || name.start_with?(".")

        host, mode = spec.to_s.split(":", 2)
        mode = "rw" if mode.nil? || mode.empty?
        raise ArgumentError, "#{path}: #{name}: mode must be ro or rw" unless %w[ro rw].include?(mode)

        host = File.expand_path(host, agent_dir)
        raise ArgumentError, "#{path}: #{name}: #{host} does not exist" unless File.exist?(host)

        "#{host}:#{ROOT}/#{name}:#{mode}"
      end
    end
  end
end
