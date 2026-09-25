# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

class SandboxAuthTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")

  def test_batch_spec_does_not_start_pi_offline
    spec = dummy_batch_spec
    refute_includes spec["Cmd"], "--offline"
    env = Array(spec["Env"])
    refute env.any? { |e| e.start_with?("PI_OFFLINE=") }, env.inspect
  end

  def test_pi_user_dir_is_agent_pi_agent_not_tmp_or_host_login
    spec = dummy_batch_spec
    env = Array(spec["Env"])
    assert_includes env, "PI_CODING_AGENT_DIR=/agent/.pi/agent"
    refute env.any? { |e| e.include?("/tmp/pi") }, env.inspect

    binds = spec.dig("HostConfig", "Binds") || []
    assert_includes binds, "#{DUMMY}:/agent:rw"
    refute binds.any? { |b| b.include?("/tmp/pi") }, binds.inspect
    host_agent = File.expand_path("~/.pi/agent")
    refute binds.any? { |b| b.start_with?("#{host_agent}:") }, binds.inspect
  end

  def test_interactive_spec_uses_same_pi_user_dir
    spec = Remuda::Sandbox.interactive_spec(DUMMY)
    env = Array(spec["Env"])
    assert_includes env, "PI_CODING_AGENT_DIR=/agent/.pi/agent"
    refute env.any? { |e| e.include?("/tmp/pi") }, env.inspect
  end

  private

  def dummy_batch_spec
    Dir.mktmpdir("remuda-prompt") do |dir|
      prompt = File.join(dir, "prompt.txt")
      File.write(prompt, "hi")
      return Remuda::Sandbox.batch_spec(DUMMY, prompt_path: prompt)
    end
  end
end
