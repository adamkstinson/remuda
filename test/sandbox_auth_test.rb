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

  def test_oauth_file_key_injected_from_dot_env
    Dir.mktmpdir("remuda-oauth") do |dir|
      File.write(File.join(dir, ".env"), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=test_key_value\n")
      spec = Remuda::Sandbox.interactive_spec(dir)
      assert_includes Array(spec["Env"]), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=test_key_value"
    end
  end

  def test_oauth_file_key_absent_without_dot_env
    Dir.mktmpdir("remuda-oauth") do |dir|
      spec = Remuda::Sandbox.interactive_spec(dir)
      refute Array(spec["Env"]).any? { |e| e.start_with?("PI_MCP_ADAPTER_OAUTH_FILE_KEY=") }, spec["Env"].inspect
    end
  end

  def test_oauth_file_key_not_read_from_process_env
    Dir.mktmpdir("remuda-oauth") do |dir|
      ENV["PI_MCP_ADAPTER_OAUTH_FILE_KEY"] = "from_process_env"
      spec = Remuda::Sandbox.interactive_spec(dir)
      refute Array(spec["Env"]).any? { |e| e.start_with?("PI_MCP_ADAPTER_OAUTH_FILE_KEY=") }, spec["Env"].inspect
    ensure
      ENV.delete("PI_MCP_ADAPTER_OAUTH_FILE_KEY")
    end
  end

  def test_oauth_file_key_in_attach_args
    Dir.mktmpdir("remuda-oauth") do |dir|
      File.write(File.join(dir, ".env"), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=test_key_value\n")
      args = Remuda::Sandbox.attach_args(dir)
      pairs = args.each_cons(2).select { |a, _| a == "-e" }.map(&:last)
      assert_includes pairs, "PI_MCP_ADAPTER_OAUTH_FILE_KEY=test_key_value"
    end
  end

  def test_oauth_file_key_in_batch_spec
    Dir.mktmpdir("remuda-oauth") do |dir|
      File.write(File.join(dir, ".env"), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=test_key_value\n")
      Dir.mktmpdir("remuda-prompt") do |prompt_dir|
        prompt = File.join(prompt_dir, "prompt.txt")
        File.write(prompt, "hi")
        spec = Remuda::Sandbox.batch_spec(dir, prompt_path: prompt)
        assert_includes Array(spec["Env"]), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=test_key_value"
      end
    end
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
