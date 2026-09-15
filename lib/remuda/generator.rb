# frozen_string_literal: true

require "fileutils"

module Remuda
  class Generator
    TEMPLATE_ROOT = File.expand_path("templates/agent", __dir__)

    def self.new_agent(dir)
      new(dir).new_agent
    end

    def initialize(dir)
      @dir = File.expand_path(dir)
    end

    def new_agent
      FileUtils.mkdir_p(@dir)
      Dir.chdir(TEMPLATE_ROOT) do
        Dir.glob("**/*", File::FNM_DOTMATCH).each do |rel|
          base = File.basename(rel)
          next if base == "." || base == ".."

          src = File.join(TEMPLATE_ROOT, rel)
          dest = File.join(@dir, rel)
          if File.directory?(src)
            FileUtils.mkdir_p(dest)
          else
            next if File.exist?(dest)

            FileUtils.mkdir_p(File.dirname(dest))
            FileUtils.cp(src, dest)
          end
        end
      end
      @dir
    end
  end
end
