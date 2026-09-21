# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "remuda"

class PiAuthTest < Minitest::Test
  def test_env_keys_synthesize_auth_json_and_select_provider
    with_agent do |agent|
      File.write(File.join(agent, ".env"), <<~ENV)
        PI_PROVIDER=anthropic
        PI_MODEL=claude-sonnet-4-5
        ANTHROPIC_API_KEY=sk-test-not-real
      ENV

      Dir.mktmpdir("stage") do |stage|
        auth_dir = Remuda::PiAuth.stage(stage, agent)
        refute_nil auth_dir
        creds = JSON.parse(File.read(File.join(auth_dir, "auth.json")))
        assert_equal "api_key", creds.dig("anthropic", "type")
        assert_equal "sk-test-not-real", creds.dig("anthropic", "key")
        assert_equal ["anthropic"], creds.keys
      end

      prompt = File.join(agent, "prompt.txt")
      File.write(prompt, "hi")
      spec = Remuda::Sandbox.batch_spec(agent, prompt_path: prompt, auth_dir: "/tmp/fake-auth")
      assert_equal "anthropic", spec["Cmd"][spec["Cmd"].index("--provider") + 1]
      assert_equal "claude-sonnet-4-5", spec["Cmd"][spec["Cmd"].index("--model") + 1]
      binds = spec.dig("HostConfig", "Binds") || []
      refute binds.any? { |b| b.include?("#{agent}/.env") }, binds.inspect
    end
  end

  def test_agent_pi_auth_json_wins_over_env_keys
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "ANTHROPIC_API_KEY=from-env\n")
      FileUtils.mkdir_p(File.join(agent, ".pi"))
      File.write(File.join(agent, ".pi/auth.json"), '{"openai":{"type":"api_key","key":"from-file"}}')

      Dir.mktmpdir("stage") do |stage|
        auth_dir = Remuda::PiAuth.stage(stage, agent)
        creds = JSON.parse(File.read(File.join(auth_dir, "auth.json")))
        assert_equal "from-file", creds.dig("openai", "key")
        refute creds.key?("anthropic")
      end
    end
  end

  def test_remuda_pi_auth_env_wins
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "ANTHROPIC_API_KEY=from-env\n")
      Dir.mktmpdir("override") do |over|
        path = File.join(over, "auth.json")
        File.write(path, '{"google":{"type":"api_key","key":"from-override"}}')
        old = ENV["REMUDA_PI_AUTH"]
        ENV["REMUDA_PI_AUTH"] = path
        Dir.mktmpdir("stage") do |stage|
          auth_dir = Remuda::PiAuth.stage(stage, agent)
          creds = JSON.parse(File.read(File.join(auth_dir, "auth.json")))
          assert_equal "from-override", creds.dig("google", "key")
        end
      ensure
        old.nil? ? ENV.delete("REMUDA_PI_AUTH") : ENV["REMUDA_PI_AUTH"] = old
      end
    end
  end

  private

  def with_agent
    Dir.mktmpdir("pi-auth-agent") do |dir|
      File.write(File.join(dir, "AGENTS.md"), "dummy\n")
      File.write(File.join(dir, "Gemfile"), "gem \"remuda\"\n")
      FileUtils.mkdir_p(File.join(dir, ".remuda/workflows"))
      yield dir
    end
  end
end
