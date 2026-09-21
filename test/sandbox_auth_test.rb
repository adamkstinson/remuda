# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

class SandboxAuthTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")

  def test_batch_spec_does_not_start_pi_offline
    spec = spec_with_staged_auth
    refute_includes spec["Cmd"], "--offline"
    env = Array(spec["Env"])
    refute env.any? { |e| e.start_with?("PI_OFFLINE=") }, env.inspect
  end

  def test_batch_spec_stages_host_auth_and_does_not_mount_agent_env
    fake_auth = nil
    spec = nil
    Dir.mktmpdir("remuda-auth") do |dir|
      fake_auth = File.join(dir, "auth.json")
      File.write(fake_auth, '{"test":true}')
      File.chmod(0o600, fake_auth)
      auth_dir = File.join(dir, "pi-agent")
      FileUtils.mkdir_p(auth_dir)
      FileUtils.cp(fake_auth, File.join(auth_dir, "auth.json"))

      prompt = File.join(dir, "prompt.txt")
      File.write(prompt, "hi")
      spec = Remuda::Sandbox.batch_spec(DUMMY, prompt_path: prompt, auth_dir: auth_dir)
    end

    binds = spec.dig("HostConfig", "Binds") || []
    assert binds.any? { |b| b.include?("/tmp/pi") }, binds.inspect
    refute binds.any? { |b| b.include?(File.join(DUMMY, ".env")) }, binds.inspect
    refute binds.any? { |b| b.split(":", 2).first.end_with?("/.env") }, binds.inspect
    host_agent = File.expand_path("~/.pi/agent")
    refute binds.any? { |b| b.start_with?("#{host_agent}:") }, binds.inspect
  end


  private

  def spec_with_staged_auth
    Dir.mktmpdir("remuda-auth") do |dir|
      prompt = File.join(dir, "prompt.txt")
      File.write(prompt, "hi")
      auth_dir = File.join(dir, "pi-agent")
      FileUtils.mkdir_p(auth_dir)
      File.write(File.join(auth_dir, "auth.json"), "{}")
      return Remuda::Sandbox.batch_spec(DUMMY, prompt_path: prompt, auth_dir: auth_dir)
    end
  end
end
