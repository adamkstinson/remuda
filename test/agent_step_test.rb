# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "remuda"

class AgentStepTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")
  DB = File.join(DUMMY, ".remuda/db/remuda.sqlite3")
  SCRIPT = File.join(DUMMY, ".remuda/workflows/call_agent.rb")

  def setup
    disconnect_db
    FileUtils.rm_f(Dir.glob("#{DB}*"))
  end

  def teardown
    disconnect_db
    FileUtils.rm_f(Dir.glob("#{DB}*"))
  end

  # Break this catches: Remuda.agent does not record an agent step in dummy SQLite
  # via remuda-pi.
  def test_dummy_agent_run_writes_workflow_steps_row
    assert File.file?(SCRIPT), "dummy needs .remuda/workflows/call_agent.rb"

    record = Remuda::Runner.new(DUMMY).run("call_agent", trigger: "manual")
    assert File.file?(DB), "expected #{DB}"

    step = Remuda::WorkflowStep.find_by(kind: "agent")
    refute_nil step, "expected a workflow_steps row with kind agent in dummy SQLite"
    assert_equal record.id, step.workflow_run_id
    output = step.output.is_a?(Hash) ? step.output : {}
    assert_equal Remuda::Image.tag, output["image"] || output[:image],
                 "agent step must run in remuda-pi, not on the host"
  end

  def test_dummy_contains_no_engine_code
    %w[lib migrate image].each do |name|
      refute File.exist?(File.join(DUMMY, name)), "dummy must not contain #{name}/"
    end
  end

  private

  def disconnect_db
    return unless defined?(ActiveRecord::Base)
    return unless ActiveRecord::Base.connected?

    ActiveRecord::Base.remove_connection
  end
end
