# frozen_string_literal: true

require "json"

module Remuda
  def self.tool(qualified_name, **args)
    server, name = qualified_name.split(".", 2)
    raise ArgumentError, "expected server.method, got #{qualified_name.inspect}" if name.nil? || name.empty?

    agent_dir = Current.agent_dir || Dir.pwd
    result = Mcp.call(server_url(agent_dir, server), name, args, token: env_token(agent_dir, server))

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

  def self.server_url(agent_dir, server)
    path = File.join(agent_dir, "mcp.json")
    config = JSON.parse(File.read(path))
    url = config.dig("mcpServers", server, "url")
    raise "unknown MCP server #{server.inspect} (no url in mcp.json)" if url.nil? || url.empty?

    url
  end

  def self.env_token(agent_dir, server)
    path = File.join(agent_dir, ".env")
    return nil unless File.file?(path)

    vars = {}
    File.foreach(path) do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      next unless key && value

      vars[key] = value.gsub(/\A["']|["']\z/, "")
    end
    token = vars["#{server.upcase}_MCP_TOKEN"] || vars["MCP_TOKEN"]
    token.nil? || token.empty? ? nil : token
  end
  private_class_method :server_url, :env_token
end
