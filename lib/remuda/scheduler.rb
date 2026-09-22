# frozen_string_literal: true

require "fugit"
require "shellwords"

module Remuda
  class Scheduler
    def self.tick(agent_dir)
      new(agent_dir).tick
    end

    def self.upsert(agent_dir, workflow:, cron:, timezone: "UTC", inputs: {})
      new(agent_dir).upsert(workflow: workflow, cron: cron, timezone: timezone, inputs: inputs)
    end

    def self.remove(agent_dir, workflow:)
      new(agent_dir).remove(workflow: workflow)
    end

    def self.list(agent_dir)
      new(agent_dir).list
    end

    def self.crontab_line(agent_dir)
      dir = File.expand_path(agent_dir)
      log = File.join(dir, ".remuda", "tick.log")
      "* * * * * cd #{Shellwords.escape(dir)} && remuda tick >> #{Shellwords.escape(log)} 2>&1"
    end

    def initialize(agent_dir)
      @agent_dir = File.expand_path(agent_dir)
    end

    def tick
      Db.connect(@agent_dir)
      now = Time.now.utc
      due = Schedule.where(paused: false).where("next_occurrence <= ?", now)
      due.find_each do |schedule|
        Runner.new(@agent_dir).run(
          schedule.workflow,
          trigger: "schedule",
          inputs: schedule.inputs || {}
        )
        schedule.update!(
          last_occurrence: now,
          next_occurrence: next_time(schedule, now)
        )
      end
    end

    def upsert(workflow:, cron:, timezone: "UTC", inputs: {})
      raise ArgumentError, "workflow is required" if workflow.nil? || workflow.empty?
      raise ArgumentError, "cron is required" if cron.nil? || cron.empty?

      parsed = parse_cron(cron, timezone)
      Db.connect(@agent_dir)
      now = Time.now.utc
      row = Schedule.find_or_initialize_by(workflow: workflow)
      row.cron = cron
      row.timezone = timezone
      row.inputs = inputs || {}
      row.paused = false
      row.next_occurrence = parsed.next_time(now).utc
      row.save!
      row
    end

    def remove(workflow:)
      raise ArgumentError, "workflow is required" if workflow.nil? || workflow.empty?

      Db.connect(@agent_dir)
      row = Schedule.find_by(workflow: workflow)
      raise ArgumentError, "no schedule for #{workflow}" if row.nil?

      row.destroy!
    end

    def list
      Db.connect(@agent_dir)
      Schedule.order(:workflow).to_a
    end

    private

    def parse_cron(cron, timezone)
      parsed = Fugit.parse_cron("#{cron} #{timezone}")
      parsed ||= Fugit.parse_cron(cron)
      raise ArgumentError, "invalid cron: #{cron.inspect}" unless parsed

      parsed
    end

    def next_time(schedule, now)
      parse_cron(schedule.cron, schedule.timezone).next_time(now).utc
    end
  end
end
