# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

class AgentModelTest < Minitest::Test
  def setup
    disconnect_db
    @dir = Dir.mktmpdir("remuda-model")
    FileUtils.mkdir_p(File.join(@dir, ".remuda", "workflows"))
    File.write(File.join(@dir, ".env"), "PI_PROVIDER=openai\nPI_MODEL=gpt-4.1\n")
    @prompt = File.join(@dir, "prompt.txt")
    File.write(@prompt, "hi")
  end

  def teardown
    disconnect_db
    FileUtils.rm_rf(@dir)
  end

  def test_batch_spec_passes_provider_and_model_from_the_call
    cmd = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt, provider: "anthropic", model: "claude-sonnet-4-5")["Cmd"]
    assert_equal ["--provider", "anthropic"], cmd[cmd.index("--provider"), 2]
    assert_equal ["--model", "claude-sonnet-4-5"], cmd[cmd.index("--model"), 2]
    assert_equal "@/run/remuda/prompt.txt", cmd.last
  end

  def test_batch_spec_passes_only_the_model_when_only_the_model_is_given
    cmd = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt, model: "gpt-4.1")["Cmd"]
    assert_equal ["--model", "gpt-4.1"], cmd[cmd.index("--model"), 2]
    refute_includes cmd, "--provider"
  end

  # Pi's settings.json is the default; .env PI_PROVIDER / PI_MODEL are not.
  def test_batch_spec_without_kwargs_leaves_the_choice_to_pi
    cmd = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt)["Cmd"]
    refute_includes cmd, "--provider"
    refute_includes cmd, "--model"
  end

  def test_agent_forwards_kwargs_and_records_them_on_the_step
    seen = nil
    fake = lambda do |_dir, _prompt, **kwargs|
      seen = kwargs
      Remuda::AgentResult.new(output: "ok", ok: true, exit_code: 0, image: "remuda-pi:latest")
    end

    with_sandbox_run(fake) do
      run = start_run
      Remuda::Current.set(run: run, agent_dir: @dir) do
        Remuda.agent("hi", provider: "anthropic", model: "claude-sonnet-4-5")
      end
    end

    assert_equal({ provider: "anthropic", model: "claude-sonnet-4-5" }, seen)
    input = Remuda::WorkflowStep.find_by(kind: "agent").input
    assert_equal "anthropic", input["provider"]
    assert_equal "claude-sonnet-4-5", input["model"]
  end

  def test_agent_without_kwargs_records_no_model
    seen = nil
    fake = lambda do |_dir, _prompt, **kwargs|
      seen = kwargs
      Remuda::AgentResult.new(output: "ok", ok: true, exit_code: 0, image: "remuda-pi:latest")
    end

    with_sandbox_run(fake) do
      run = start_run
      Remuda::Current.set(run: run, agent_dir: @dir) { Remuda.agent("hi") }
    end

    assert_equal({ provider: nil, model: nil }, seen)

    assert_equal({ "prompt" => "hi" }, Remuda::WorkflowStep.find_by(kind: "agent").input)
  end

  private

  def start_run
    Remuda::Db.connect(@dir)
    Remuda::WorkflowRun.create!(workflow: "w", status: "running", trigger: "manual", started_at: Time.now.utc)
  end

  def with_sandbox_run(fake)
    original = Remuda::Sandbox.method(:run)
    Remuda::Sandbox.define_singleton_method(:run, &fake)
    yield
  ensure
    Remuda::Sandbox.define_singleton_method(:run, original)
  end

  def disconnect_db
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
  end
end
