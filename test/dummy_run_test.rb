# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "remuda"

class DummyRunTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")
  DB = File.join(DUMMY, ".remuda/db/remuda.sqlite3")
  SCRIPT = File.join(DUMMY, ".remuda/workflows/hello.rb")

  def setup
    disconnect_db
    FileUtils.rm_f(Dir.glob("#{DB}*"))
  end

  def teardown
    disconnect_db
    FileUtils.rm_f(Dir.glob("#{DB}*"))
  end

  # Break this catches: tick does not run a due schedule through the gem
  # into this agent's SQLite.
  def test_scheduled_tick_writes_workflow_runs_row_in_dummy_sqlite
    assert File.file?(SCRIPT), "dummy needs .remuda/workflows/hello.rb"

    Remuda::Db.connect(DUMMY)
    Remuda::Schedule.create!(
      workflow: "hello",
      cron: "* * * * *",
      timezone: "UTC",
      paused: false,
      next_occurrence: Time.utc(2000, 1, 1)
    )

    Remuda::Scheduler.tick(DUMMY)

    assert File.file?(DB), "expected #{DB}"
    run = Remuda::WorkflowRun.find_by(workflow: "hello")
    refute_nil run, "expected a workflow_runs row for hello"
    assert_equal "schedule", run.trigger
    assert_includes %w[ok error], run.status
    refute_nil run.finished_at
  end

  # Break this catches: a still-running workflow is started again instead of skipped.
  def test_tick_skips_when_same_workflow_still_running
    Remuda::Db.connect(DUMMY)
    Remuda::WorkflowRun.create!(
      workflow: "hello",
      status: "running",
      trigger: "manual",
      started_at: Time.now.utc
    )
    Remuda::Schedule.create!(
      workflow: "hello",
      cron: "* * * * *",
      timezone: "UTC",
      paused: false,
      next_occurrence: Time.utc(2000, 1, 1)
    )

    Remuda::Scheduler.tick(DUMMY)

    skipped = Remuda::WorkflowRun.find_by(workflow: "hello", status: "skipped")
    refute_nil skipped, "expected a skipped workflow_runs row"
    assert_equal "schedule", skipped.trigger
    assert_equal 1, Remuda::WorkflowRun.where(status: "running").count
  end

  # Break this catches: engine code copied into the agent directory.
  def test_dummy_contains_no_engine_code
    %w[lib migrate image].each do |name|
      path = File.join(DUMMY, name)
      refute File.exist?(path), "dummy must not contain #{name}/"
    end
  end

  private

  def disconnect_db
    return unless defined?(ActiveRecord::Base)
    return unless ActiveRecord::Base.connected?

    ActiveRecord::Base.remove_connection
  end
end
