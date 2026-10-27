# frozen_string_literal: true

module Remuda
  # provider: / model: override Pi's default (defaultProvider / defaultModel
  # in the agent's .pi/agent/settings.json) for this one call. session_id:
  # resumes that Pi session, creating it if it is missing; pass the id a
  # previous run returned to continue the same conversation.
  # tools: / exclude_tools: narrow the catalog for this one call (ToolPolicy).
  #
  # If the run ends in a provider error and the agent declares a fallback in
  # .remuda/model.yml, it is retried once against that provider/model (#71).
  def self.agent(prompt, provider: nil, model: nil, session_id: nil, tools: nil, exclude_tools: nil, **_kwargs)
    agent_dir = Current.agent_dir || Dir.pwd
    policy = ToolPolicy.new(tools: tools, exclude_tools: exclude_tools)
    servers = Channels.bound?(agent_dir) ? [ChannelsMcp::SERVER] : []
    policy.validate!(local_servers: servers)
    result = Sandbox.run(agent_dir, prompt, provider: provider, model: model, session_id: session_id, policy: policy)

    fallback = ModelConfig.fallback(agent_dir)
    used_fallback = fallback && result.model_error
    if used_fallback
      result = Sandbox.run(agent_dir, prompt, provider: fallback[:provider], model: fallback[:model],
                           session_id: session_id, policy: policy)
    end

    if Current.run
      output = {
        "text" => AgentFailure.scrub(result.output, agent_dir),
        "image" => result.image,
        "exit_code" => result.exit_code
      }
      output["fallback"] = fallback_record(fallback, result) if used_fallback
      WorkflowStep.create!(
        workflow_run_id: Current.run.id,
        kind: "agent",
        position: WorkflowStep.where(workflow_run_id: Current.run.id).count + 1,
        name: "agent",
        input: { "prompt" => prompt.to_s, "provider" => provider, "model" => model, "session_id" => session_id,
                 "tools" => tools, "exclude_tools" => exclude_tools }.compact,
        output: output,
        session_id: result.session_id,
        usage: result.usage,
        error: result.ok ? nil : AgentFailure.describe(result, agent_dir)
      )
    end

    result
  end

  # What the step shows for a fallback run: that it happened, and the
  # provider/model Pi actually served it with (the fallback config, or the
  # agent's own default when the retry left a key out).
  def self.fallback_record(fallback, result)
    record = { "used" => true }
    provider = result.provider || fallback[:provider]
    model = result.model || fallback[:model]
    record["provider"] = provider if provider
    record["model"] = model if model
    record
  end
  private_class_method :fallback_record
end
