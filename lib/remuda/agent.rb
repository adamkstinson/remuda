# frozen_string_literal: true

module Remuda
  def self.agent(prompt, **_kwargs)
    agent_dir = Current.agent_dir || Dir.pwd
    result = Sandbox.run(agent_dir, prompt)

    if Current.run
      WorkflowStep.create!(
        workflow_run_id: Current.run.id,
        kind: "agent",
        position: WorkflowStep.where(workflow_run_id: Current.run.id).count + 1,
        name: "agent",
        input: { "prompt" => prompt.to_s },
        output: {
          "text" => result.output,
          "image" => result.image,
          "exit_code" => result.exit_code
        },
        session_id: result.session_id,
        usage: result.usage,
        error: result.ok ? nil : result.output.to_s[0, 2000]
      )
    end

    result
  end
end
