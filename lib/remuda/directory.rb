# frozen_string_literal: true

module Remuda
  module Directory
    def self.find(path = nil)
      dir = File.expand_path(path || Dir.pwd)
      unless agent?(dir)
        raise ArgumentError, "#{dir} is not a remuda agent directory"
      end

      dir
    end

    def self.agent?(dir)
      File.file?(File.join(dir, "AGENTS.md")) && gemfile_names_remuda?(dir)
    end

    def self.gemfile(dir)
      File.join(File.expand_path(dir), ".remuda", "Gemfile")
    end

    def self.gemfile_names_remuda?(dir)
      path = gemfile(dir)
      File.file?(path) && File.read(path).match?(/\bgem\s+["']remuda["']/)
    end

    def self.env_vars(dir)
      path = File.join(File.expand_path(dir), ".env")
      return {} unless File.file?(path)

      vars = {}
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, value = line.split("=", 2)
        next unless key && value

        vars[key] = value.gsub(/\A["']|["']\z/, "")
      end
      vars
    end
  end
end
