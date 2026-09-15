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

    def self.gemfile_names_remuda?(dir)
      path = File.join(dir, "Gemfile")
      File.file?(path) && File.read(path).match?(/\bgem\s+["']remuda["']/)
    end
  end
end
