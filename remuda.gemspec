# frozen_string_literal: true

require_relative "lib/remuda/version"

Gem::Specification.new do |spec|
  spec.name = "remuda"
  spec.version = Remuda::VERSION
  spec.authors = ["Adam K Stinson"]
  spec.email = ["hello@adamkstinson.com"]
  spec.summary = "Rails for agent harnesses"
  spec.description = "One Ruby gem that builds, runs, and maintains agent directories."
  spec.homepage = "https://github.com/adamkstinson/remuda"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.start_with?("test/", "design/", "projects/", "adr/", ".")
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
