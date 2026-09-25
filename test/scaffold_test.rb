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

  # Break this catches: dummy is missing identity or harness files.
  def test_dummy_is_an_agent_directory
    assert File.directory?(DUMMY), "expected test/dummy agent fixture"
    assert File.file?(File.join(DUMMY, "AGENTS.md")), "dummy needs AGENTS.md"
    refute File.exist?(File.join(DUMMY, "CLAUDE.md")), "dummy must not have CLAUDE.md"
    gemfile = File.read(File.join(DUMMY, ".remuda/Gemfile"))
    assert_match(/\bgem\s+["']remuda["']/, gemfile)
  end

  # Break this catches: dummy root missing the files Pi and the operator look at.
  def test_dummy_root_has_agent_facing_files
    assert File.file?(File.join(DUMMY, "mcp.json")), "dummy needs mcp.json"
    assert File.file?(File.join(DUMMY, ".remuda/Gemfile")), "dummy needs .remuda/Gemfile"
    gemfile = File.read(File.join(DUMMY, ".remuda/Gemfile"))
    assert_match(/\bgem\s+["']remuda["']/, gemfile)
    assert File.directory?(File.join(DUMMY, "files")), "dummy needs files/"
    assert File.directory?(File.join(DUMMY, ".pi")), "dummy needs .pi/"
    assert File.file?(File.join(DUMMY, ".env.example")), "dummy needs .env.example"
  end

  # Break this catches: harness instance at dummy root, or missing .remuda/.
  def test_dummy_harness_instance_lives_under_dot_remuda
    remuda = File.join(DUMMY, ".remuda")
    assert File.directory?(File.join(remuda, "workflows")), "dummy needs .remuda/workflows/"
    assert File.file?(File.join(remuda, "channels.yml")), "dummy needs .remuda/channels.yml"
    assert File.directory?(File.join(remuda, "db")), "dummy needs .remuda/db/"
    assert File.directory?(File.join(remuda, "bin")), "dummy needs .remuda/bin/"
    refute File.exist?(File.join(DUMMY, "workflows")),
           "workflows/ belongs under .remuda/, not dummy root"
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
