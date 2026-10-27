# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "remuda"

# A failed sandboxed pi used to leave only an exit code on the agent step
# (#65): error was the parsed output, which is "" when pi dies before saying
# anything. The step now keeps pi's stderr and the last JSON event it printed,
# with the agent's secrets scrubbed out.
class AgentFailureTest < Minitest::Test
  SECRET = "dh_supersecretvalue1234567890"
  AUTH_SECRET = "sk-auth-json-secret-0987654321"

  # Stands in for a finished container. Docker returns stdout and stderr
  # separately or together depending on the flags.
  FakeContainer = Struct.new(:status, :stdout, :stderr) do
    def start = self
    def wait(_seconds) = { "StatusCode" => status }
    def delete(**) = true

    def logs(stdout: false, stderr: false)
      [(stdout ? self.stdout : ""), (stderr ? self.stderr : "")].join
    end
  end

  def setup
    disconnect_db
    @dir = Dir.mktmpdir("remuda-agent-failure")
    File.write(File.join(@dir, "AGENTS.md"), "test agent\n")
    File.write(File.join(@dir, ".env"), "DARKHORSE_API_KEY=#{SECRET}\nSHORT=abc\n")
    FileUtils.mkdir_p(File.join(@dir, ".pi/agent"))
    File.write(File.join(@dir, ".pi/agent/auth.json"),
               JSON.generate("openai" => { "type" => "api_key", "key" => AUTH_SECRET }))
    FileUtils.mkdir_p(File.join(@dir, ".remuda/workflows"))
    File.write(File.join(@dir, ".remuda/workflows/call_agent.rb"), "Remuda.agent(\"hi\")\n")
  end

  def teardown
    disconnect_db
    FileUtils.rm_rf(@dir)
  end

  def test_a_startup_crash_records_stderr_in_the_step_error
    stderr = "No API key found for the selected model.\n"
    step = run_with(FakeContainer.new(1, session_line, stderr))

    refute_nil step.error
    refute_empty step.error
    assert_includes step.error, "exit 1"
    assert_includes step.error, "No API key found for the selected model."
    assert_includes step.error, '"type":"session"'
    assert_equal 1, step.output["exit_code"]
  end

  def test_a_cutoff_after_output_records_the_last_json_event
    events = [session_line, JSON.generate("type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta" }) + "\n"]
    step = run_with(FakeContainer.new(1, events.join, ""))

    assert_includes step.error, "exit 1"
    assert_includes step.error, '"type":"message_update"'
    assert_includes step.error, "stderr: (empty)"
  end

  def test_only_the_tail_of_a_long_stderr_is_kept
    stderr = "early-line\n" + ("x" * 10_000) + "\nfinal-line\n"
    step = run_with(FakeContainer.new(1, "", stderr))

    assert_includes step.error, "final-line"
    refute_includes step.error, "early-line"
    assert_operator step.error.bytesize, :<=, Remuda::AgentFailure::MAX_ERROR_BYTES
  end

  def test_secrets_from_env_and_auth_json_never_reach_the_database
    stderr = "401 for key #{SECRET} and #{AUTH_SECRET}\n"
    last = JSON.generate("type" => "error", "errorMessage" => "bad key #{SECRET}")
    step = run_with(FakeContainer.new(1, "#{last}\n", stderr))

    refute_includes step.error, SECRET
    refute_includes step.error, AUTH_SECRET
    assert_includes step.error, "[REDACTED]"
    stored = Remuda::WorkflowStep.connection.select_all("SELECT * FROM workflow_steps").rows.flatten.join(" ")
    refute_includes stored, SECRET
    refute_includes stored, AUTH_SECRET
  end

  def test_a_successful_run_records_no_error
    done = JSON.generate("type" => "message_end",
                         "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "pong" }] })
    step = run_with(FakeContainer.new(0, "#{done}\n", "some harmless stderr\n"))

    assert_nil step.error
    assert_equal "pong", step.output["text"]
  end

  # Pi exits 0 when the provider refuses the call; the agent step used to
  # record ok with empty text and 0 tokens (#70).
  def test_a_provider_error_on_an_exit_zero_run_fails_the_step
    error_line = provider_error("xai API error (403): out of credits")
    step = run_with(FakeContainer.new(0, "#{error_line}\n", ""))

    refute_nil step.error
    assert_includes step.error, "xai API error (403): out of credits"
    assert_includes step.error, "exit 0"
  end

  def test_a_provider_error_makes_the_result_not_ok
    error_line = provider_error("out of credits")
    result = with_fake_create(-> { FakeContainer.new(0, "#{error_line}\n", "") }) do
      Remuda::Sandbox.run(@dir, "hi")
    end

    refute result.ok
    assert_equal 0, result.exit_code
    assert_equal "out of credits", result.pi_error
  end

  def test_a_provider_error_fails_the_workflow_run
    File.write(File.join(@dir, ".remuda/workflows/guarded_agent.rb"), <<~RUBY)
      result = Remuda.agent("hi")
      raise "agent failed: \#{result.output}" unless result.ok
    RUBY
    error_line = provider_error("out of credits")
    record = with_fake_create(-> { FakeContainer.new(0, "#{error_line}\n", "") }) do
      Remuda::Runner.new(@dir).run("guarded_agent", trigger: "manual")
    end

    assert_equal "error", record.status
    assert_includes record.exception_message, "out of credits"
  end

  def test_a_provider_error_still_lets_a_guarded_workflow_succeed
    File.write(File.join(@dir, ".remuda/workflows/guarded_agent.rb"), <<~RUBY)
      result = Remuda.agent("hi")
      raise "agent failed: \#{result.output}" unless result.ok
    RUBY
    done = JSON.generate("type" => "message_end",
                         "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "pong" }] },
                         "stopReason" => "stop")
    record = with_fake_create(-> { FakeContainer.new(0, "#{done}\n", "") }) do
      Remuda::Runner.new(@dir).run("guarded_agent", trigger: "manual")
    end

    assert_equal "ok", record.status
  end

  private

  def provider_error(message)
    JSON.generate("type" => "message_end",
                  "message" => { "role" => "assistant", "content" => [] },
                  "stopReason" => "error",
                  "errorMessage" => message)
  end

  def session_line
    JSON.generate("type" => "session", "version" => 3, "id" => "01a15ca9-0000-7000-8000-000000000000", "cwd" => "/agent") + "\n"
  end

  def run_with(container)
    with_fake_create(-> { container }) do
      Remuda::Runner.new(@dir).run("call_agent", trigger: "manual")
    end
    Remuda::WorkflowStep.find_by(kind: "agent").tap { |step| refute_nil step, "expected an agent step" }
  end

  def with_fake_create(factory)
    original = Docker::Container.method(:create)
    Docker::Container.define_singleton_method(:create) { |*_args| factory.call }
    yield
  ensure
    Docker::Container.define_singleton_method(:create, original)
  end

  def disconnect_db
    return unless defined?(ActiveRecord::Base)
    return unless ActiveRecord::Base.connected?

    ActiveRecord::Base.remove_connection
  end
end
