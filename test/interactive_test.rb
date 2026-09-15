# frozen_string_literal: true

require "test_helper"
require "remuda"

class InteractiveTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")

  def test_bare_remuda_spec_uses_same_image_as_agent
    spec = Remuda::Sandbox.interactive_spec(DUMMY)
    assert_equal Remuda::Image.tag, spec["Image"]
    assert_equal ["pi"], spec["Entrypoint"]
  end

  def test_interactive_keeps_db_and_ruby_on_the_host
    spec = Remuda::Sandbox.interactive_spec(DUMMY)
    binds = spec.dig("HostConfig", "Binds") || []
    refute binds.any? { |b| b.include?(".remuda/db") }, "must not mount dummy SQLite"
    refute binds.any? { |b| b.split(":", 2).first.end_with?("/.env") || b.include?(":/.env") },
           "must not mount .env"
    refute binds.any? { |b| b.include?("/lib/remuda") }, "workflow Ruby stays on the host gem"
  end

  def test_cli_bare_invokes_sandbox_attach
    source = File.read(File.join(ROOT, "lib/remuda/cli.rb"))
    assert_match(/Sandbox\.attach/, source)
  end

  def test_dummy_contains_no_engine_code
    %w[lib migrate image].each do |name|
      refute File.exist?(File.join(DUMMY, name)), "dummy must not contain #{name}/"
    end
  end
end
