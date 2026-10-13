# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

class ToolPolicyTest < Minitest::Test
  def setup
    disconnect_db
    @dir = Dir.mktmpdir("remuda-policy")
    FileUtils.mkdir_p(File.join(@dir, ".remuda", "workflows"))
    File.write(File.join(@dir, ".remuda", "channels.yml"), "transports:\n  recorder: {}\n")
    @prompt = File.join(@dir, "prompt.txt")
    File.write(@prompt, "hi")
  end

  def teardown
    disconnect_db
    FileUtils.rm_rf(@dir)
  end

  # --- ToolPolicy ------------------------------------------------------------

  def test_tools_and_exclude_tools_together_raise
    error = assert_raises(ArgumentError) do
      Remuda::ToolPolicy.new(tools: %w[read], exclude_tools: %w[bash])
    end
    assert_match(/mutually exclusive/, error.message)
  end

  def test_a_bad_tool_name_raises
    assert_raises(ArgumentError) { Remuda::ToolPolicy.new(tools: ["read; rm -rf"]).validate! }
    assert_raises(ArgumentError) { Remuda::ToolPolicy.new(exclude_tools: ["a b"]).validate! }
  end

  def test_an_array_allowlist_has_no_pins
    policy = Remuda::ToolPolicy.new(tools: %w[read grep channels_send_message])
    assert_equal %w[read grep channels_send_message], policy.allow
    assert_empty policy.pins
    assert_nil policy.deny
  end

  def test_a_hash_allowlist_keeps_pins_with_string_keys
    policy = Remuda::ToolPolicy.new(
      tools: {
        "read" => true,
        "channels_send_message" => { jid: "mattermost:abc", thread_id: "t-1" },
        "channels_list_channels" => {}
      }
    )
    assert_equal %w[read channels_send_message channels_list_channels], policy.allow
    assert_equal({ "channels_send_message" => { "jid" => "mattermost:abc", "thread_id" => "t-1" } }, policy.pins)
  end

  def test_pins_are_only_valid_for_tools_the_host_answers
    policy = Remuda::ToolPolicy.new(tools: { "planet_list_work_items" => { project: "X" } })
    error = assert_raises(ArgumentError) { policy.validate!(local_servers: %w[channels]) }
    assert_match(/planet_list_work_items/, error.message)

    policy = Remuda::ToolPolicy.new(tools: { "channels_send_message" => { jid: "rec:town" } })
    assert_same policy, policy.validate!(local_servers: %w[channels])
  end

  def test_pi_args_are_the_allow_deny_or_no_tools_flags
    assert_equal [], Remuda::ToolPolicy.new.pi_args
    assert_equal ["--tools", "read,grep"], Remuda::ToolPolicy.new(tools: %w[read grep]).pi_args
    assert_equal ["--no-tools"], Remuda::ToolPolicy.new(tools: []).pi_args
    assert_equal ["--no-tools"], Remuda::ToolPolicy.new(tools: {}).pi_args
    assert_equal ["--exclude-tools", "bash,write,edit"],
                 Remuda::ToolPolicy.new(exclude_tools: %w[bash write edit]).pi_args
    assert_equal [], Remuda::ToolPolicy.new(exclude_tools: []).pi_args
  end

  # --- batch_spec ------------------------------------------------------------

  def test_batch_spec_passes_an_allowlist
    cmd = batch_spec(Remuda::ToolPolicy.new(tools: %w[read grep]))["Cmd"]
    assert_equal ["--tools", "read,grep"], cmd[cmd.index("--tools"), 2]
    refute_includes cmd, "--exclude-tools"
    refute_includes cmd, "--no-tools"
    assert_equal "@/run/remuda/prompt.txt", cmd.last
  end

  def test_batch_spec_passes_a_denylist
    cmd = batch_spec(Remuda::ToolPolicy.new(exclude_tools: %w[bash write edit]))["Cmd"]
    assert_equal ["--exclude-tools", "bash,write,edit"], cmd[cmd.index("--exclude-tools"), 2]
    refute_includes cmd, "--tools"
  end

  def test_batch_spec_empty_allowlist_means_no_tools
    cmd = batch_spec(Remuda::ToolPolicy.new(tools: []))["Cmd"]
    assert_includes cmd, "--no-tools"
    refute_includes cmd, "--tools"
    refute_includes cmd, "--exclude-tools"
  end

  def test_batch_spec_accepts_an_allowlist_directly
    cmd = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt, tools: %w[read grep])["Cmd"]
    assert_equal ["--tools", "read,grep"], cmd[cmd.index("--tools"), 2]
  end

  def test_batch_spec_accepts_a_denylist_directly
    cmd = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt, exclude_tools: %w[bash write])["Cmd"]
    assert_equal ["--exclude-tools", "bash,write"], cmd[cmd.index("--exclude-tools"), 2]
  end

  # --- Remuda.agent ----------------------------------------------------------

  def test_agent_records_the_allowlist_and_pins_on_the_step
    seen = nil
    with_sandbox_run(fake_run { |kwargs| seen = kwargs }) do
      run = start_run
      Remuda::Current.set(run: run, agent_dir: @dir) do
        Remuda.agent("hi", tools: { "channels_send_message" => { jid: "rec:town" } })
      end
    end

    assert_instance_of Remuda::ToolPolicy, seen[:policy]
    assert_equal({ "channels_send_message" => { "jid" => "rec:town" } }, seen[:policy].pins)
    input = Remuda::WorkflowStep.find_by(kind: "agent").input
    assert_equal ["channels_send_message"], input["tools"].keys
    assert_equal({ "jid" => "rec:town" }, input["tools"]["channels_send_message"])
  end

  def test_agent_records_a_denylist
    seen = nil
    with_sandbox_run(fake_run { |kwargs| seen = kwargs }) do
      run = start_run
      Remuda::Current.set(run: run, agent_dir: @dir) do
        Remuda.agent("hi", exclude_tools: %w[bash write])
      end
    end

    assert_equal %w[bash write], seen[:policy].deny
    input = Remuda::WorkflowStep.find_by(kind: "agent").input
    assert_equal %w[bash write], input["exclude_tools"]
  end

  def test_agent_refuses_pins_on_tools_the_host_does_not_answer_before_the_sandbox
    called = false
    with_sandbox_run(fake_run { |_kwargs| called = true }) do
      error = assert_raises(ArgumentError) do
        Remuda::Current.set(agent_dir: @dir) do
          Remuda.agent("hi", tools: { "planet_list_work_items" => { project: "X" } })
        end
      end
      assert_match(/planet_list_work_items/, error.message)
    end
    refute called, "the sandbox must not start for an invalid pin"
  end

  private

  def batch_spec(policy)
    Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt, policy: policy)
  end

  def fake_run
    lambda do |_dir, _prompt, **kwargs|
      yield kwargs
      Remuda::AgentResult.new(output: "ok", ok: true, exit_code: 0, image: "remuda-pi:latest")
    end
  end

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
