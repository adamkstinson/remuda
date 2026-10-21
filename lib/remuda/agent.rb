# frozen_string_literal: true

module Remuda
  # provider: / model: override Pi's default (defaultProvider / defaultModel
  # in the agent's .pi/agent/settings.json) for this one call. session_id:
  # resumes that Pi session, creating it if it is missing; pass the id a
  # previous run returned to continue the same conversation.
  # tools: / exclude_tools: narrow the catalog for this one call (ToolPolicy).
  def self.agent(prompt, provider: nil, model: nil, session_id: nil, tools: nil, exclude_tools: nil, **_kwargs)
    agent_dir = Current.agent_dir || Dir.pwd
    policy = ToolPolicy.new(tools: tools, exclude_tools: exclude_tools)
    servers = Channels.bound?(agent_dir) ? [ChannelsMcp::SERVER] : []
    policy.validate!(local_servers: servers)
    result = Sandbox.run(agent_dir, prompt, provider: provider, model: model, session_id: session_id, policy: policy)

    if Current.run
      WorkflowStep.create!(
        workflow_run_id: Current.run.id,
        kind: "agent",
        position: WorkflowStep.where(workflow_run_id: Current.run.id).count + 1,
        name: "agent",
        input: { "prompt" => prompt.to_s, "provider" => provider, "model" => model, "session_id" => session_id,
                 "tools" => tools, "exclude_tools" => exclude_tools }.compact,
        output: {
          "text" => AgentFailure.scrub(result.output, agent_dir),
          "image" => result.image,
          "exit_code" => result.exit_code
        },
        session_id: result.session_id,
        usage: result.usage,
        error: result.ok ? nil : AgentFailure.describe(result, agent_dir)
      )
    end

    result
  end
end
