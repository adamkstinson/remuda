# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "remuda"

class ConsoleTest < Minitest::Test
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

  # Break this catches: remuda console does not load dummy SQLite / WorkflowRun.
  def test_console_from_dummy_can_query_workflow_run
    Remuda::Db.connect(DUMMY)
    Remuda::WorkflowRun.create!(
      workflow: "hello",
      status: "ok",
      trigger: "manual",
      started_at: Time.now.utc,
      finished_at: Time.now.utc
    )
    disconnect_db

    stdout, stderr, status = invoke_console(DUMMY, "puts WorkflowRun.count\nexit\n")
    assert_equal 0, status.exitstatus, stderr
    assert File.file?(DB), "expected #{DB}"
    assert_match(/\b1\b/, stdout, "expected WorkflowRun.count to print 1, got #{stdout.inspect}")
  end

  # Break this catches: console starts Pi / the sandbox.
  def test_console_does_not_start_pi
    source = File.read(File.join(ROOT, "lib/remuda/cli.rb"))
    refute_match(/sandbox|docker|remuda-pi/i, console_method(source))
  end

  private

  def console_method(source)
    source[/def console\n.*?\n    end/m] || source
  end

  def invoke_console(dir, stdin)
    env = { "RUBYLIB" => File.join(ROOT, "lib") }
    Open3.capture3(env, Gem.ruby, EXE, "console", dir, stdin_data: stdin)
  end

  def disconnect_db
    return unless defined?(ActiveRecord::Base)
    return unless ActiveRecord::Base.connected?

    ActiveRecord::Base.remove_connection
  end
end
