# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "remuda"

class AgentFallbackTest < Minitest::Test
  # Stands in for a finished container; Docker returns stdout and stderr
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
    @dir = Dir.mktmpdir("remuda-fallback")
    FileUtils.mkdir_p(File.join(@dir, ".remuda", "workflows"))
  end

  def teardown
    disconnect_db
    FileUtils.rm_rf(@dir)
  end

  # ── .remuda/model.yml ─────────────────────────────────────────────────────

  def test_no_config_file_means_no_fallback
    assert_nil Remuda::ModelConfig.fallback(@dir)
  end

  def test_a_fallback_block_names_the_provider_and_model
    write_model_yml(<<~YAML)
      fallback:
        provider: anthropic
        model: claude-sonnet-4-5
    YAML

    assert_equal({ provider: "anthropic", model: "claude-sonnet-4-5" },
                 Remuda::ModelConfig.fallback(@dir))
  end

  def test_either_key_may_be_omitted
    write_model_yml(<<~YAML)
      fallback:
        model: gpt-4.1
    YAML

    assert_equal({ provider: nil, model: "gpt-4.1" }, Remuda::ModelConfig.fallback(@dir))
  end

  def test_an_empty_fallback_block_means_no_fallback
    write_model_yml("fallback: {}\n")
    assert_nil Remuda::ModelConfig.fallback(@dir)
  end

  def test_the_shipped_template_declares_no_fallback_by_default
    assert_nil Remuda::ModelConfig.fallback(File.expand_path("../lib/remuda/templates/agent", __dir__))
  end

  # ── retry ────────────────────────────────────────────────────────────────

  def test_a_provider_error_retries_once_on_the_configured_fallback
    write_fallback(provider: "anthropic", model: "claude-sonnet-4-5")
    failed = provider_error_result
    succeeded = success_result(output: "pong")
    calls = []
    fake = lambda do |_dir, _prompt, **kwargs|
      calls << kwargs
      calls.one? ? failed : succeeded
    end

    result = with_sandbox_run(fake) { in_run { Remuda.agent("hi") } }

    assert_equal 2, calls.length
    assert_nil calls.first[:provider]
    assert_nil calls.first[:model]
    assert_equal "anthropic", calls.last[:provider]
    assert_equal "claude-sonnet-4-5", calls.last[:model]
    assert result.ok
    assert_equal "pong", result.output
  end

  def test_the_step_records_the_fallback_and_what_served_it
    write_fallback(provider: "anthropic", model: "claude-sonnet-4-5")
    failed = provider_error_result
    succeeded = success_result(output: "pong")
    fake = ->(_dir, _prompt, **kwargs) { kwargs[:provider] == "anthropic" ? succeeded : failed }

    with_sandbox_run(fake) { in_run { Remuda.agent("hi") } }

    step = Remuda::WorkflowStep.find_by(kind: "agent")
    assert_equal({ "used" => true, "provider" => "anthropic", "model" => "claude-sonnet-4-5" },
                 step.output["fallback"])
    assert_nil step.error
  end

  def test_a_run_that_succeeds_first_does_not_use_the_fallback
    write_fallback(provider: "anthropic", model: "claude-sonnet-4-5")
    succeeded = success_result(output: "pong")
    calls = []
    fake = lambda do |_dir, _prompt, **kwargs|
      calls << kwargs
      succeeded
    end

    with_sandbox_run(fake) { in_run { Remuda.agent("hi") } }

    assert_equal 1, calls.length
    assert_nil Remuda::WorkflowStep.find_by(kind: "agent").output["fallback"]
  end

  def test_a_non_provider_failure_does_not_use_the_fallback
    write_fallback(provider: "anthropic", model: "claude-sonnet-4-5")
    crashed = Remuda::AgentResult.new(output: "", ok: false, exit_code: 1, image: "remuda-pi:latest")
    calls = []
    fake = lambda do |_dir, _prompt, **kwargs|
      calls << kwargs
      crashed
    end

    with_sandbox_run(fake) { in_run { Remuda.agent("hi") } }

    assert_equal 1, calls.length
  end

  def test_a_provider_error_without_a_fallback_does_not_retry
    failed = provider_error_result
    calls = []
    fake = lambda do |_dir, _prompt, **kwargs|
      calls << kwargs
      failed
    end

    result = with_sandbox_run(fake) { in_run { Remuda.agent("hi") } }

    assert_equal 1, calls.length
    refute result.ok
  end

  def test_a_failed_fallback_is_recorded_on_the_step
    write_fallback(provider: "anthropic", model: "claude-sonnet-4-5")
    failed = provider_error_result(message: "still down")
    fake = ->(_dir, _prompt, **_kwargs) { failed }

    with_sandbox_run(fake) { in_run { Remuda.agent("hi") } }

    step = Remuda::WorkflowStep.find_by(kind: "agent")
    assert_equal true, step.output.dig("fallback", "used")
    refute_nil step.error
    assert_includes step.error, "still down"
  end

  def test_the_record_prefers_what_pi_reported_over_the_config
    write_model_yml("fallback:\n  model: gpt-4.1\n")
    failed = provider_error_result
    succeeded = success_result(output: "pong", provider: "openai")
    fake = ->(_dir, _prompt, **kwargs) { kwargs[:model] == "gpt-4.1" ? succeeded : failed }

    with_sandbox_run(fake) { in_run { Remuda.agent("hi") } }

    assert_equal({ "used" => true, "provider" => "openai", "model" => "gpt-4.1" },
                 Remuda::WorkflowStep.find_by(kind: "agent").output["fallback"])
  end

  # The whole path: Sandbox.run reads pi's JSONL, Remuda.agent retries the
  # fallback in a second container, and the step says what happened.
  def test_a_provider_error_falls_back_through_a_real_sandbox_run
    write_fallback(provider: "anthropic", model: "claude-sonnet-4-5")
    containers = [
      FakeContainer.new(0, "#{provider_error_line('out of credits')}\n", ""),
      FakeContainer.new(0, "#{assistant_line('pong', provider: 'anthropic', model: 'claude-sonnet-4-5')}\n", "")
    ]
    specs = []
    with_fake_container_create(containers, specs) { in_run { Remuda.agent("hi") } }

    assert_equal 2, specs.length
    refute_includes specs.first["Cmd"].join(" "), "anthropic"
    assert_includes specs.last["Cmd"].join(" "), "--provider anthropic"
    assert_includes specs.last["Cmd"].join(" "), "--model claude-sonnet-4-5"
    step = Remuda::WorkflowStep.find_by(kind: "agent")
    assert_equal({ "used" => true, "provider" => "anthropic", "model" => "claude-sonnet-4-5" },
                 step.output["fallback"])
    assert_nil step.error
  end

  private

  def provider_error_line(message)
    JSON.generate("type" => "message_end",
                  "message" => { "role" => "assistant", "content" => [] },
                  "stopReason" => "error", "errorMessage" => message)
  end

  def assistant_line(text, provider:, model:)
    JSON.generate("type" => "message_end",
                  "message" => { "role" => "assistant", "provider" => provider, "model" => model,
                                 "content" => [{ "type" => "text", "text" => text }] },
                  "stopReason" => "stop")
  end

  def with_fake_container_create(containers, specs)
    original = Docker::Container.method(:create)
    Docker::Container.define_singleton_method(:create) do |*args|
      specs << args.first
      containers.shift
    end
    yield
  ensure
    Docker::Container.define_singleton_method(:create, original)
  end

  def write_fallback(provider:, model:)
    write_model_yml("fallback:\n  provider: #{provider}\n  model: #{model}\n")
  end

  def provider_error_result(message: "out of credits")
    Remuda::AgentResult.new(output: message, ok: false, exit_code: 0, image: "remuda-pi:latest",
                            pi_error: message, model_error: true)
  end

  def success_result(output:, provider: nil, model: nil)
    Remuda::AgentResult.new(output: output, ok: true, exit_code: 0, image: "remuda-pi:latest",
                            provider: provider, model: model)
  end

  def in_run
    Remuda::Db.connect(@dir)
    run = Remuda::WorkflowRun.create!(workflow: "w", status: "running", trigger: "manual", started_at: Time.now.utc)
    Remuda::Current.set(run: run, agent_dir: @dir) { yield }
  end

  def with_sandbox_run(fake)
    original = Remuda::Sandbox.method(:run)
    Remuda::Sandbox.define_singleton_method(:run, &fake)
    yield
  ensure
    Remuda::Sandbox.define_singleton_method(:run, original)
  end

  def write_model_yml(body)
    FileUtils.mkdir_p(File.join(@dir, ".remuda"))
    File.write(File.join(@dir, ".remuda", "model.yml"), body)
  end

  def disconnect_db
    return unless defined?(ActiveRecord::Base)
    return unless ActiveRecord::Base.connected?

    ActiveRecord::Base.remove_connection
  end
end
