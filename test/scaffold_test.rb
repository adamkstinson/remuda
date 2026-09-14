# frozen_string_literal: true

require "test_helper"

class ScaffoldTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")

  # Break this catches: gemspec missing or named something other than remuda.
  def test_root_gemspec_loads_as_gem_named_remuda
    path = File.join(ROOT, "remuda.gemspec")
    assert File.file?(path), "expected remuda.gemspec at repo root"

    spec = Gem::Specification.load(path)
    refute_nil spec, "remuda.gemspec did not load"
    assert_equal "remuda", spec.name
  end

  # Break this catches: dummy is not an agent (no identity file, or Gemfile
  # does not name the remuda harness).
  def test_dummy_is_an_agent_directory
    assert File.directory?(DUMMY), "expected test/dummy agent fixture"
    assert File.file?(File.join(DUMMY, "AGENTS.md")), "dummy needs AGENTS.md"
    gemfile = File.read(File.join(DUMMY, "Gemfile"))
    assert_match(/\bgem\s+["']remuda["']/, gemfile)
  end

  # Break this catches: engine code copied into the agent directory.
  def test_dummy_contains_no_engine_code
    assert File.directory?(DUMMY), "expected test/dummy agent fixture"
    %w[lib migrate image].each do |name|
      path = File.join(DUMMY, name)
      refute File.exist?(path), "dummy must not contain #{name}/"
    end
  end
end
