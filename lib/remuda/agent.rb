# frozen_string_literal: true

module Remuda
  # provider: / model: override Pi's default (defaultProvider / defaultModel
  # in the agent's .pi/agent/settings.json) for this one call.
  def self.agent(prompt, provider: nil, model: nil, **_kwargs)
    agent_dir = Current.agent_dir || Dir.pwd
    result = Sandbox.run(agent_dir, prompt, provider: provider, model: model)

    if Current.run
      WorkflowStep.create!(
        workflow_run_id: Current.run.id,
        kind: "agent",
        position: WorkflowStep.where(workflow_run_id: Current.run.id).count + 1,
        name: "agent",
        input: { "prompt" => prompt.to_s, "provider" => provider, "model" => model }.compact,
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
