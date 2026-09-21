# frozen_string_literal: true

require "json"

module Remuda
  def self.tools(agent_dir)
    config = mcp_config(agent_dir)
    (config["mcpServers"] || {}).flat_map do |server, spec|
      url = spec.is_a?(Hash) ? spec["url"] : nil
      next [] if url.nil? || url.empty?

      Mcp.list(
        url,
        token: env_token(agent_dir, server),
        headers: server_headers(agent_dir, spec)
      ).map do |tool|
        {
          server: server,
          name: tool["name"],
          description: tool["description"],
          input_schema: tool["inputSchema"]
        }
      end
    end
  end

  def self.tool(qualified_name, **args)
    server, name = qualified_name.split(".", 2)
    raise ArgumentError, "expected server.method, got #{qualified_name.inspect}" if name.nil? || name.empty?

    agent_dir = Current.agent_dir || Dir.pwd
    spec = mcp_config(agent_dir).dig("mcpServers", server)
    result = Mcp.call(
      server_url(agent_dir, server),
      name,
      args,
      token: env_token(agent_dir, server),
      headers: server_headers(agent_dir, spec)
    )

    if Current.run
      WorkflowStep.create!(
        workflow_run_id: Current.run.id,
        kind: "tool",
        position: WorkflowStep.where(workflow_run_id: Current.run.id).count + 1,
        name: qualified_name,
        input: args,
        output: result
      )
    end

    result
  end

  def self.mcp_config(agent_dir)
    path = File.join(agent_dir, "mcp.json")
    JSON.parse(File.read(path))
  end

  def self.server_url(agent_dir, server)
    url = mcp_config(agent_dir).dig("mcpServers", server, "url")
    raise "unknown MCP server #{server.inspect} (no url in mcp.json)" if url.nil? || url.empty?

    url
  end

  def self.server_headers(agent_dir, spec)
    return {} unless spec.is_a?(Hash)

    headers = spec["headers"]
    return {} unless headers.is_a?(Hash)

    vars = Directory.env_vars(agent_dir)
    headers.each_with_object({}) do |(key, value), out|
      out[key] = interpolate(value.to_s, vars)
    end
  end

  def self.interpolate(value, vars)
    value.gsub(/\{\{(\w+)\}\}/) { vars[$1] || ENV[$1] || "" }
  end

  def self.env_token(agent_dir, server)
    vars = Directory.env_vars(agent_dir)
    token = vars["#{server.upcase}_MCP_TOKEN"] || vars["MCP_TOKEN"]
    token.nil? || token.empty? ? nil : token
  end
  private_class_method :mcp_config, :server_url, :server_headers, :interpolate, :env_token
end
