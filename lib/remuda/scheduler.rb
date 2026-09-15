# frozen_string_literal: true

require "fugit"

module Remuda
  class Scheduler
    def self.tick(agent_dir)
      new(agent_dir).tick
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

    private

    def next_time(schedule, now)
      cron = Fugit.parse_cron("#{schedule.cron} #{schedule.timezone}")
      cron ||= Fugit.parse_cron(schedule.cron)
      cron.next_time(now).utc
    end
  end
end
