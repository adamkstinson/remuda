# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

class SchedulerClaimTest < Minitest::Test
  def setup
    disconnect_db
    @dir = Dir.mktmpdir("remuda-scheduler")
    FileUtils.mkdir_p(File.join(@dir, ".remuda", "workflows"))
    @probe = File.join(@dir, "probe.txt")
    File.write(File.join(@dir, ".remuda", "workflows", "probe.rb"), <<~RUBY)
      row = Remuda::Schedule.find_by(workflow: "probe")
      due = Remuda::Schedule.where("next_occurrence <= ?", Time.now.utc).count
      File.write(#{@probe.inspect}, [row.next_occurrence.to_i, due].join(","))
    RUBY
  end

  def teardown
    disconnect_db
    FileUtils.rm_rf(@dir)
  end

  # Break this catches: next_occurrence advances only after the run finishes,
  # so a tick in the next cron minute sees the schedule as still due.
  def test_tick_claims_the_schedule_before_the_workflow_runs
    Remuda::Db.connect(@dir)
    Remuda::Schedule.create!(
      workflow: "probe", cron: "* * * * *", timezone: "UTC",
      paused: false, next_occurrence: Time.utc(2000, 1, 1)
    )

    Remuda::Scheduler.tick(@dir)

    next_at, due = File.read(@probe).split(",").map(&:to_i)
    assert_operator next_at, :>, Time.now.utc.to_i - 60, "next_occurrence was not advanced before the run"
    assert_equal 0, due, "schedule was still due while its workflow ran"
    assert_equal "ok", Remuda::WorkflowRun.find_by(workflow: "probe").status
  end

  # Break this catches: two ticks that both read the row before either writes
  # each run the workflow (or write a skipped row).
  def test_tick_does_not_run_a_schedule_another_tick_already_claimed
    Remuda::Db.connect(@dir)
    schedule = Remuda::Schedule.create!(
      workflow: "probe", cron: "* * * * *", timezone: "UTC",
      paused: false, next_occurrence: Time.utc(2000, 1, 1)
    )
    stale = Remuda::Schedule.find(schedule.id)
    schedule.update!(next_occurrence: Time.utc(2000, 1, 1, 0, 1))

    scheduler = Remuda::Scheduler.new(@dir)
    refute scheduler.send(:claim, stale, Time.now.utc), "claimed a row another tick already advanced"
    assert scheduler.send(:claim, Remuda::Schedule.find(schedule.id), Time.now.utc)
  end

  private

  def disconnect_db
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
  end
end
