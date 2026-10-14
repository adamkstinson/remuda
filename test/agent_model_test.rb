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

  def test_batch_spec_passes_session_id_so_pi_resumes_it
    uuid = "12345678-1234-1234-1234-123456789abc"
    cmd = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt, session_id: uuid)["Cmd"]
    assert_equal ["--session-id", uuid], cmd[cmd.index("--session-id"), 2]
    assert_equal "@/run/remuda/prompt.txt", cmd.last
  end

  def test_batch_spec_without_a_session_id_lets_pi_make_one
    cmd = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt)["Cmd"]
    refute_includes cmd, "--session-id"
  end

  # A session id reaches a container command line, so anything but hex and
  # dashes is refused before it gets there.
  def test_batch_spec_rejects_a_non_uuid_session_id
    error = assert_raises(ArgumentError) do
      Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt, session_id: "x; rm -rf /")
    end
    assert_match(/session_id/, error.message)
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

    assert_equal "anthropic", seen[:provider]
    assert_equal "claude-sonnet-4-5", seen[:model]
    assert_nil seen[:session_id]
    assert_instance_of Remuda::ToolPolicy, seen[:policy]
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

    assert_nil seen[:model]
    assert_nil seen[:provider]
    assert_nil seen[:session_id]
    assert_instance_of Remuda::ToolPolicy, seen[:policy]

    assert_equal({ "prompt" => "hi" }, Remuda::WorkflowStep.find_by(kind: "agent").input)
  end

  # Break this catches: a resumed run recording a session id that is not the
  # one it asked Pi to resume.
  def test_agent_resumes_the_given_session_and_records_the_same_id
    uuid = "12345678-1234-1234-1234-123456789abc"
    fake = lambda do |_dir, _prompt, **kwargs|
      Remuda::AgentResult.new(output: "ok", session_id: kwargs[:session_id],
                              ok: true, exit_code: 0, image: "remuda-pi:latest")
    end

    with_sandbox_run(fake) do
      run = start_run
      Remuda::Current.set(run: run, agent_dir: @dir) { Remuda.agent("hi", session_id: uuid) }
    end

    step = Remuda::WorkflowStep.find_by(kind: "agent")
    assert_equal uuid, step.input["session_id"]
    assert_equal uuid, step.session_id
  end

  # Break this catches: a thread's second turn starting from zero because the
  # listener did not reuse the session the mapping gave it.
  def test_two_turns_in_one_thread_record_the_same_session_id
    registry = Remuda::Channels::Registry.new(agent_dir: @dir)
    fake = lambda do |_dir, _prompt, **kwargs|
      Remuda::AgentResult.new(output: "ok", session_id: kwargs[:session_id],
                              ok: true, exit_code: 0, image: "remuda-pi:latest")
    end

    run = start_run
    with_sandbox_run(fake) do
      Remuda::Current.set(run: run, agent_dir: @dir) do
        2.times do
          Remuda.agent("turn", session_id: registry.session_for(jid: "mattermost:c1", thread_id: "t1"))
        end
      end
    end

    steps = Remuda::WorkflowStep.where(kind: "agent").order(:position)
    assert_equal 2, steps.count
    refute_nil steps.first.session_id
    assert_equal steps.first.session_id, steps.last.session_id
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
