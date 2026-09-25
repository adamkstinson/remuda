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

    def self.coding?(agent_dir)
      root = File.expand_path(agent_dir)
      File.file?(File.join(root, ".remuda/Gemfile")) ||
        File.file?(File.join(root, ".remuda/workflows/poll-and-execute.rb"))
    end

    def self.for(agent_dir)
      coding?(agent_dir) ? coding_tag : tag
    end
  end
end
