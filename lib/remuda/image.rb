# frozen_string_literal: true

module Remuda
  module Image
    PI = "remuda-pi:latest"
    CODING = "remuda-coding:latest"

    def self.tag
      PI
    end

    def self.coding_tag
      CODING
    end

    def self.for(agent_dir)
      path = File.join(File.expand_path(agent_dir), ".remuda", "image")
      return tag unless File.file?(path)

      line = File.read(path).strip
      line.empty? ? tag : line
    end
  end
end
