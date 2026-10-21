# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "remuda"

# Provider keys in the agent's .env reach Pi through the agent's own Pi user
# dir: the runner writes them into <agent>/.pi/agent/auth.json on the host,
# which the sandbox sees as $PI_CODING_AGENT_DIR/auth.json. .env itself is
# never mounted.
class PiAuthTest < Minitest::Test
  def test_env_keys_are_written_to_the_agents_auth_json_without_selecting_model
    with_agent do |agent|
      File.write(File.join(agent, ".env"), <<~ENV)
        PI_PROVIDER=anthropic
        PI_MODEL=claude-sonnet-4-5
        ANTHROPIC_API_KEY=sk-test-not-real
        OPENAI_API_KEY=sk-other-not-selected
      ENV

      assert Remuda::PiAuth.sync!(agent)
      creds = read_auth(agent)
      assert_equal({ "anthropic" => { "type" => "api_key", "key" => "sk-test-not-real" } }, creds)
      assert_equal 0o600, File.stat(auth_path(agent)).mode & 0o777

      prompt = File.join(agent, "prompt.txt")
      File.write(prompt, "hi")
      spec = Remuda::Sandbox.batch_spec(agent, prompt_path: prompt)
      refute_includes spec["Cmd"], "--provider"
      refute_includes spec["Cmd"], "--model"
      binds = spec.dig("HostConfig", "Binds") || []
      refute binds.any? { |b| b.start_with?("#{agent}/.env:") }, binds.inspect
    end
  end

  def test_darkhorse_api_key_is_written_as_the_darkhorse_provider
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "DARKHORSE_API_KEY=dh-test-not-real\n")

      Remuda::PiAuth.sync!(agent)
      assert_equal({ "darkhorse" => { "type" => "api_key", "key" => "dh-test-not-real" } }, read_auth(agent))
    end
  end

  # A login made inside `remuda` (OAuth or a pasted key) for another provider
  # stays; .env only owns the providers it names.
  def test_existing_entries_for_other_providers_are_kept
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "DARKHORSE_API_KEY=dh-new\n")
      write_auth(agent, "anthropic" => { "type" => "oauth", "access" => "a", "refresh" => "r", "expires" => 1 })

      Remuda::PiAuth.sync!(agent)
      creds = read_auth(agent)
      assert_equal "oauth", creds.dig("anthropic", "type")
      assert_equal "dh-new", creds.dig("darkhorse", "key")
    end
  end

  # Rotating the key in .env takes effect on the next run.
  def test_env_wins_for_the_providers_it_names
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "DARKHORSE_API_KEY=dh-rotated\n")
      write_auth(agent, "darkhorse" => { "type" => "api_key", "key" => "dh-old" })

      assert Remuda::PiAuth.sync!(agent)
      assert_equal "dh-rotated", read_auth(agent).dig("darkhorse", "key")
    end
  end

  def test_an_unchanged_file_is_not_rewritten
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "DARKHORSE_API_KEY=dh-same\n")
      write_auth(agent, "darkhorse" => { "type" => "api_key", "key" => "dh-same" })
      before = File.read(auth_path(agent))

      refute Remuda::PiAuth.sync!(agent)
      assert_equal before, File.read(auth_path(agent))
    end
  end

  def test_no_env_keys_leaves_the_pi_dir_alone
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "GH_TOKEN=ghp_not_a_model_key\n")

      refute Remuda::PiAuth.sync!(agent)
      refute File.exist?(auth_path(agent)), "must not create auth.json without a provider key"
    end
  end

  # Never copies the operator's own login into an agent.
  def test_does_not_fall_back_to_host_login
    with_agent do |agent|
      refute Remuda::PiAuth.sync!(agent)
      refute File.exist?(auth_path(agent))
    end
  end

  # pi owns the file's format. If it is not a JSON object, leave it for a
  # human rather than overwrite a login.
  def test_an_unreadable_auth_json_is_not_overwritten
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "DARKHORSE_API_KEY=dh-x\n")
      FileUtils.mkdir_p(File.dirname(auth_path(agent)))
      File.write(auth_path(agent), "{not json")

      _out, err = capture_io { refute Remuda::PiAuth.sync!(agent) }
      assert_equal "{not json", File.read(auth_path(agent))
      assert_match(/auth\.json/, err)
      refute_includes err, "dh-x"
    end
  end

  def test_sandbox_run_writes_auth_json_before_the_container_starts
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "DARKHORSE_API_KEY=dh-run\n")
      seen = nil
      fake = Struct.new(:x) do
        def start = self
        def wait(_s) = { "StatusCode" => 0 }
        def logs(**) = ""
        def delete(**) = true
      end
      original = Docker::Container.method(:create)
      Docker::Container.define_singleton_method(:create) do |*_args|
        seen = File.file?(File.join(agent, ".pi/agent/auth.json")) && JSON.parse(File.read(File.join(agent, ".pi/agent/auth.json")))
        fake.new(nil)
      end
      begin
        Remuda::Sandbox.run(agent, "hi")
      ensure
        Docker::Container.define_singleton_method(:create, original)
      end
      assert_equal "dh-run", seen && seen.dig("darkhorse", "key")
    end
  end

  def test_interactive_attach_writes_auth_json_before_docker_runs
    with_agent do |agent|
      File.write(File.join(agent, ".env"), "DARKHORSE_API_KEY=dh-attach\n")
      seen = nil
      Remuda::Sandbox.define_singleton_method(:system) do |*_args|
        seen = JSON.parse(File.read(File.join(agent, ".pi/agent/auth.json")))
        true
      end
      begin
        Remuda::Sandbox.attach(agent)
      ensure
        Remuda::Sandbox.singleton_class.send(:remove_method, :system)
      end
      assert_equal "dh-attach", seen && seen.dig("darkhorse", "key")
    end
  end

  private

  def auth_path(agent) = File.join(agent, ".pi", "agent", "auth.json")

  def read_auth(agent) = JSON.parse(File.read(auth_path(agent)))

  def write_auth(agent, data)
    FileUtils.mkdir_p(File.dirname(auth_path(agent)))
    File.write(auth_path(agent), JSON.generate(data))
  end

  def with_agent
    Dir.mktmpdir("pi-auth-agent") do |dir|
      File.write(File.join(dir, "AGENTS.md"), "dummy\n")
      FileUtils.mkdir_p(File.join(dir, ".remuda"))
      File.write(File.join(dir, ".remuda/Gemfile"), "gem \"remuda\"\n")
      FileUtils.mkdir_p(File.join(dir, ".remuda/workflows"))
      yield dir
    end
  end
end
