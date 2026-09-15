# frozen_string_literal: true

module Remuda
  class Runner
    def initialize(agent_dir)
      @agent_dir = File.expand_path(agent_dir)
    end

    def run(workflow, trigger:, inputs: {})
      Db.connect(@agent_dir)

      if WorkflowRun.exists?(workflow: workflow, status: "running")
        return WorkflowRun.create!(
          workflow: workflow,
          status: "skipped",
          trigger: trigger,
          inputs: inputs,
          started_at: Time.now.utc,
          finished_at: Time.now.utc
        )
      end

      record = WorkflowRun.create!(
        workflow: workflow,
        status: "running",
        trigger: trigger,
        inputs: inputs,
        started_at: Time.now.utc
      )

      begin
        Current.set(run: record, agent_dir: @agent_dir, inputs: inputs) do
          Dir.chdir(@agent_dir) { load File.join(@agent_dir, ".remuda", "workflows", "#{workflow}.rb") }
        end
        record.update!(status: "ok", finished_at: Time.now.utc)
      rescue StandardError => e
        record.update!(
          status: "error",
          exception_class: e.class.name,
          exception_message: e.message,
          finished_at: Time.now.utc
        )
      end

      record.reload
    end
  end
end
