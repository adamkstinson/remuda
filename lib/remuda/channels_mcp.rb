# frozen_string_literal: true

require "json"

module Remuda
  # The sandbox's channels tool. A minimal MCP server (Streamable HTTP, JSON
  # responses, one tool) that the per-run forwarder answers in-process on the
  # host, so the agent can send_message while the channel token stays in the
  # host .env. Each send is a workflow step on the run that started the box.
  class ChannelsMcp
    SERVER = "channels"
    PROTOCOL = "2025-06-18"

    def self.routes(agent_dir, run: nil)
      Channels.bound?(agent_dir) ? { SERVER => new(agent_dir, run: run) } : {}
    end

    def initialize(agent_dir, run: nil)
      @agent_dir = File.expand_path(agent_dir)
      @run = run
      @lock = Mutex.new
    end

    # -> [status, headers, body]
    def call(method, body)
      return [405, { "Allow" => "POST" }, ""] unless method == "POST"

      message = JSON.parse(body.to_s)
      replies = message.is_a?(Array) ? message.filter_map { |m| handle(m) } : [handle(message)].compact
      return [202, {}, ""] if replies.empty?

      payload = message.is_a?(Array) ? replies : replies.first
      [200, { "Content-Type" => "application/json" }, JSON.generate(payload)]
    rescue JSON::ParserError
      [400, { "Content-Type" => "application/json" },
       JSON.generate(jsonrpc: "2.0", id: nil, error: { code: -32_700, message: "parse error" })]
    end

    private

    def handle(message)
      return nil unless message.is_a?(Hash) && message.key?("id")

      id = message["id"]
      params = message["params"].is_a?(Hash) ? message["params"] : {}
      result = case message["method"]
               when "initialize"
                 {
                   protocolVersion: params["protocolVersion"] || PROTOCOL,
                   capabilities: { tools: {} },
                   serverInfo: { name: "remuda-channels", version: VERSION }
                 }
               when "ping" then {}
               when "tools/list"
                 { tools: Channels::TOOLS.values.map do |tool|
                   { name: tool::NAME, description: tool::DESCRIPTION, inputSchema: tool::SCHEMA }
                 end }
               when "tools/call" then call_tool(params)
               else
                 return { jsonrpc: "2.0", id: id, error: { code: -32_601, message: "method not found" } }
               end
      { jsonrpc: "2.0", id: id, result: result }
    end

    def call_tool(params)
      name = params["name"]
      tool = Channels::TOOLS[name]
      raise ArgumentError, "unknown tool #{name.inspect}" unless tool

      args = (params["arguments"].is_a?(Hash) ? params["arguments"] : {}).dup
      args["files"] = Array(args["files"]).map { |path| host_file(path) } if args["files"]
      output = tool.call(registry, args)
      record(name, args, output, nil)
      { content: [{ type: "text", text: JSON.generate(output) }] }
    rescue StandardError => e
      record(name, args, nil, e.message) if args
      { content: [{ type: "text", text: e.message }], isError: true }
    end

    def registry
      @lock.synchronize { @registry ||= Channels.load(@agent_dir) }
    end

    # The agent names files as it sees them, under /agent. Only files that
    # are in the agent directory on the host, and not the ones the box never
    # gets (.env, .remuda/), can be attached.
    def host_file(path)
      path = path.to_s
      raise ArgumentError, "#{path}: attach files from under /agent" unless path.start_with?("/agent/")

      root = File.realpath(@agent_dir)
      real = File.realpath(File.join(root, path.delete_prefix("/agent/")))
      inside = real.delete_prefix("#{root}/")
      if !real.start_with?("#{root}/") || inside == ".env" || inside.start_with?(".env.") ||
         inside == ".remuda" || inside.start_with?(".remuda/")
        raise ArgumentError, "#{path}: not a file the agent may send"
      end

      real
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise ArgumentError, "#{path}: no such file"
    end

    def record(name, args, output, error)
      return unless @run

      ActiveRecord::Base.connection_pool.with_connection do
        WorkflowStep.create!(
          workflow_run_id: @run.id,
          kind: "tool",
          position: WorkflowStep.where(workflow_run_id: @run.id).count + 1,
          name: "#{SERVER}.#{name}",
          input: args,
          output: output,
          error: error
        )
      end
    end
  end
end
