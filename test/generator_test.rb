# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class GeneratorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXE = File.join(ROOT, "exe/remuda")

  def test_new_on_empty_dir_writes_agent_layout_without_engine
    Dir.mktmpdir("remuda-new") do |dir|
      status, err = invoke("new", dir)
      assert_equal 0, status, err

      assert File.file?(File.join(dir, "AGENTS.md")), "needs AGENTS.md"
      refute File.exist?(File.join(dir, "CLAUDE.md")), "never CLAUDE.md"
      gemfile = File.read(File.join(dir, "Gemfile"))
      assert_match(/\bgem\s+["']remuda["']/, gemfile)
      assert File.file?(File.join(dir, "mcp.json"))
      assert File.file?(File.join(dir, ".env.example"))
      assert File.directory?(File.join(dir, ".pi"))
      assert File.directory?(File.join(dir, "files"))
      assert File.directory?(File.join(dir, ".remuda/db"))
      assert File.directory?(File.join(dir, ".remuda/workflows"))
      assert File.directory?(File.join(dir, ".remuda/bin"))
      assert File.file?(File.join(dir, ".remuda/channels.yml"))

      %w[lib migrate image].each do |name|
        refute File.exist?(File.join(dir, name)), "must not contain #{name}/"
      end
      refute File.exist?(File.join(dir, "templates")), "templates stay in the gem"
    end
  end

  def test_new_does_not_overwrite_existing_files
    Dir.mktmpdir("remuda-new") do |dir|
      agents = File.join(dir, "AGENTS.md")
      File.write(agents, "keep me\n")
      status, err = invoke("new", dir)
      assert_equal 0, status, err
      assert_equal "keep me\n", File.read(agents)
    end
  end

  def test_templates_live_in_the_gem
    path = File.join(ROOT, "lib/remuda/templates/agent")
    assert File.directory?(path), "expected generator templates in the gem"
  end

  private

  def invoke(*args)
    env = { "RUBYLIB" => File.join(ROOT, "lib") }
    stdout, stderr, status = Open3.capture3(env, Gem.ruby, EXE, *args)
    [status.exitstatus, stderr.empty? ? stdout : "#{stdout}\n#{stderr}"]
  end
end
