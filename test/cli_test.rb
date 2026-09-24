# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "remuda"

class CliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")
  DB = File.join(DUMMY, ".remuda/db/remuda.sqlite3")
  EXE = File.join(ROOT, "exe/remuda")

  def setup
    disconnect_db
    FileUtils.rm_f(Dir.glob("#{DB}*"))
  end

  def teardown
    disconnect_db
    FileUtils.rm_f(Dir.glob("#{DB}*"))
  end

  # Break this catches: remuda run does not go through Runner into dummy SQLite.
  def test_remuda_run_records_workflow_run_via_runner
    assert File.file?(EXE), "expected exe/remuda in the gem"

    status, stderr = invoke("run", DUMMY, "hello")
    assert_equal 0, status, stderr
    assert File.file?(DB), "expected #{DB}"

    Remuda::Db.connect(DUMMY)
    run = Remuda::WorkflowRun.find_by(workflow: "hello")
    refute_nil run, "expected a workflow_runs row for hello"
    assert_equal "manual", run.trigger
    assert_equal "ok", run.status
  end

  # Break this catches: remuda tick is a second path, not Scheduler/Runner.
  def test_remuda_tick_records_through_same_runner
    assert File.file?(EXE), "expected exe/remuda in the gem"

    Remuda::Db.connect(DUMMY)
    Remuda::Schedule.create!(
      workflow: "hello",
      cron: "* * * * *",
      timezone: "UTC",
      paused: false,
      next_occurrence: Time.utc(2000, 1, 1)
    )
    disconnect_db

    status, stderr = invoke("tick", DUMMY)
    assert_equal 0, status, stderr

    Remuda::Db.connect(DUMMY)
    run = Remuda::WorkflowRun.find_by(workflow: "hello", trigger: "schedule")
    refute_nil run, "expected a scheduled workflow_runs row from remuda tick"
    assert_includes %w[ok skipped], run.status
  end

  # Break this catches: remuda schedule only exists as console/SQL.
  def test_remuda_schedule_inserts_row_without_console
    assert File.file?(EXE), "expected exe/remuda in the gem"

    status, output = invoke("schedule", DUMMY, "hello", "--cron", "0 7 * * *")
    assert_equal 0, status, output
    assert_match(/scheduled hello 0 7 \* \* \*/, output)
    assert_match(%r{\* \* \* \* \* cd #{Regexp.escape(DUMMY)} && remuda tick}, output)
    refute_match(/bundle exec/, output)
    refute_match(/\.agentworks\/bin\/tick/, output)

    Remuda::Db.connect(DUMMY)
    row = Remuda::Schedule.find_by(workflow: "hello")
    refute_nil row, "expected a schedules row from remuda schedule"
    assert_equal "0 7 * * *", row.cron
    assert_equal "UTC", row.timezone
    refute row.paused
    refute_nil row.next_occurrence
  end

  def test_remuda_schedule_prints_pacific_when_zone_is_los_angeles
    status, output = invoke("schedule", DUMMY, "hello", "--cron", "0 * * * *", "--timezone", "America/Los_Angeles")
    assert_equal 0, status, output
    assert_match(/next=\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} P[DS]T/, output)
    refute_match(/\+00:00/, output)
  end

  def test_remuda_schedule_rejects_invalid_cron
    status, output = invoke("schedule", DUMMY, "hello", "--cron", "not-a-cron")
    assert_equal 1, status, output
    assert_match(/invalid cron/, output)

    Remuda::Db.connect(DUMMY)
    assert_nil Remuda::Schedule.find_by(workflow: "hello")
  end

  # Break this catches: CLI copied into the dummy agent.
  def test_dummy_does_not_contain_cli_binary
    refute File.exist?(File.join(DUMMY, "exe")), "dummy must not contain exe/"
    refute File.exist?(File.join(DUMMY, "remuda")), "dummy must not contain remuda binary"
    %w[lib migrate image].each do |name|
      refute File.exist?(File.join(DUMMY, name)), "dummy must not contain #{name}/"
    end
  end

  private

  def invoke(*args)
    env = { "RUBYLIB" => File.join(ROOT, "lib") }
    stdout, stderr, status = Open3.capture3(env, Gem.ruby, EXE, *args)
    [status.exitstatus, stderr.empty? ? stdout : "#{stdout}\n#{stderr}"]
  end

  def disconnect_db
    return unless defined?(ActiveRecord::Base)
    return unless ActiveRecord::Base.connected?

    ActiveRecord::Base.remove_connection
  end
end
