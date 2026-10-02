# frozen_string_literal: true

# End-to-end check that Pi in the sandbox image has an MCP client, reads the
# agent's mcp.json, and calls a header-declared server through the forwarder
# without the key entering the box. Needs Docker and the image built from
# image/. Not part of `rake test`.
#
#   docker build -t remuda-pi:latest image/
#   ruby -Ilib test/integration/mcp_client.rb
#
# IMAGE=remuda-coding:latest checks the coding image. REMUDA_CHECK_NETWORK=host
# runs the container on the host network, for a host whose firewall drops
# docker0 -> host traffic.
#
# A fake Plane MCP server and a fake OpenAI-compatible model run on the host.
# The model calls plane_list_projects, then channels_send_message on a bound
# test transport; the check passes when both land on the host.
require "remuda"
require "fileutils"
require "tmpdir"
require "socket"
require "json"

LOG = []
SENT = []
CALL = { tool: "plane_list_projects", args: "{}" }
IMAGE = ENV.fetch("IMAGE", "remuda-pi:latest")
HOST_NETWORK = ENV["REMUDA_CHECK_NETWORK"] == "host"
MODEL_BIND = HOST_NETWORK ? "127.0.0.1" : Remuda::McpForwarder.bind_address
MODEL_HOST = HOST_NETWORK ? "127.0.0.1" : "host.docker.internal"

def http_server(bind, &handler)
  srv = TCPServer.new(bind, 0)
  Thread.new do
    loop do
      c = srv.accept
      Thread.new(c) do |s|
        line = s.gets.to_s
        h = {}
        while (l = s.gets) && l != "\r\n"; k, v = l.split(":", 2); h[k.downcase.strip] = v.to_s.strip; end
        body = h["content-length"] ? s.read(h["content-length"].to_i) : ""
        handler.call(s, line.split[0], line.split[1], h, body)
      rescue => e
        warn "server err #{e.class} #{e.message}"
      ensure
        s.close rescue nil
      end
    end
  end
  srv
end

def reply(s, code, type, body, extra = {})
  hdr = extra.map { |k, v| "#{k}: #{v}\r\n" }.join
  s.write("HTTP/1.1 #{code} OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n#{hdr}Connection: close\r\n\r\n#{body}")
end

# Fake Plane MCP (streamable HTTP, JSON responses)
plane = http_server("127.0.0.1") do |s, method, path, h, body|
  LOG << "MCP #{method} #{path} key=#{h["x-plane-key"].inspect}"
  next reply(s, 401, "text/plain", "bad key") unless h["x-plane-key"] == "sekrit"
  next reply(s, 405, "text/plain", "") unless method == "POST"
  msg = JSON.parse(body)
  LOG << "MCP rpc #{msg["method"]}"
  next reply(s, 202, "text/plain", "") unless msg["id"]
  result = case msg["method"]
  when "initialize" then { protocolVersion: msg.dig("params", "protocolVersion") || "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "fake-plane", version: "1" } }
  when "tools/list" then { tools: [{ name: "list_projects", description: "List Plane projects", inputSchema: { type: "object", properties: {} } }] }
  when "tools/call" then { content: [{ type: "text", text: "projects: Alpha, Beta" }] }
  else {}
  end
  reply(s, 200, "application/json", JSON.generate(jsonrpc: "2.0", id: msg["id"], result: result), "Mcp-Session-Id" => "sess-1")
end

# Fake OpenAI-compatible model
model = http_server(MODEL_BIND) do |s, method, path, h, body|
  req = JSON.parse(body) rescue {}
  tools = Array(req["tools"]).map { |t| t.dig("function", "name") }
  LOG << "LLM #{path} tools=#{tools.inspect}"
  tool_msg = Array(req["messages"]).reverse.find { |m| m["role"] == "tool" }
  chunk = ->(delta, fin = nil) { "data: #{JSON.generate(id: "c", object: "chat.completion.chunk", created: 0, model: "fake", choices: [{ index: 0, delta: delta, finish_reason: fin }])}\n\n" }
  sse = if tool_msg
    content = tool_msg["content"].is_a?(Array) ? tool_msg["content"].map { |p| p["text"] }.join : tool_msg["content"].to_s
    chunk.({ role: "assistant", content: "TOOL SAID: #{content}" }) + chunk.({}, "stop")
  else
    name, args = tools.include?(CALL[:tool]) ? [CALL[:tool], CALL[:args]] : ["mcp", JSON.generate(tool: CALL[:tool], args: CALL[:args])]
    chunk.({ role: "assistant", tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: name, arguments: args } }] }) + chunk.({}, "tool_calls")
  end
  sse += "data: [DONE]\n\n"
  s.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n#{sse}")
end

dir = Dir.mktmpdir("remuda-mcp-check")
at_exit { FileUtils.rm_rf(dir) }
FileUtils.mkdir_p(["#{dir}/.remuda/workflows", "#{dir}/.pi/agent"])
File.write("#{dir}/AGENTS.md", "Test agent.\n")
FileUtils.mkdir_p("#{dir}/files")
File.write("#{dir}/files/note.txt", "note")
File.write("#{dir}/.remuda/channels.yml", "transports:\n  recorder: {}\n")

# A channel transport that records instead of posting.
class Recorder < Remuda::Channels::Channel
  def self.from_config(*) = new
  def name = "recorder"
  def owns_jid?(jid) = jid.start_with?("rec:")
  def send_message(**message) = (SENT << message; "thread-9")
end
Remuda::Channels.register_transport("recorder", Recorder)
File.write("#{dir}/.remuda/image", "#{IMAGE}\n")
File.write("#{dir}/.env", "PLANE_API_KEY=sekrit\n")
File.write("#{dir}/mcp.json", JSON.pretty_generate(
  "settings" => { "toolPrefix" => "server" },
  "mcpServers" => { "plane" => { "url" => "http://127.0.0.1:#{plane.addr[1]}/mcp", "headers" => { "X-Plane-Key" => "{{PLANE_API_KEY}}" }, "directTools" => true } }))
File.write("#{dir}/.pi/agent/models.json", JSON.pretty_generate(
  "providers" => { "fake" => { "baseUrl" => "http://#{MODEL_HOST}:#{model.addr[1]}/v1", "api" => "openai-completions", "apiKey" => "x",
    "compat" => { "supportsDeveloperRole" => false, "supportsReasoningEffort" => false },
    "models" => [{ "id" => "fake-model" }] } }))
File.write("#{dir}/.pi/agent/settings.json", JSON.pretty_generate("defaultProvider" => "fake", "defaultModel" => "fake-model"))

if HOST_NETWORK
  class << Remuda::Sandbox
    alias_method :check_batch_spec, :batch_spec
    def batch_spec(*args, **kwargs)
      check_batch_spec(*args, **kwargs).tap { |spec| spec["HostConfig"]["NetworkMode"] = "host" }
    end
  end
end

result = Remuda::Sandbox.run(dir, "List the Plane projects.")
puts LOG
puts "output: #{result.output}"
offered = LOG.any? { |line| line.start_with?("LLM") && line.include?("plane_list_projects") }
called = LOG.include?("MCP rpc tools/call")
keyed = LOG.grep(/\AMCP (POST|GET)/).all? { |line| line.include?('key="sekrit"') }
answered = result.output.to_s.include?("projects: Alpha, Beta")

LOG.clear
CALL.merge!(tool: "channels_send_message",
            args: JSON.generate(jid: "rec:ops", text: "hello from the box", files: ["/agent/files/note.txt"]))
sent = Remuda::Sandbox.run(dir, "Say hello on the channel.")
puts LOG
puts "output: #{sent.output}"
delivered = SENT.size == 1 && SENT.first[:text] == "hello from the box" &&
            SENT.first[:files] == [File.join(File.realpath(dir), "files/note.txt")]

checks = { "Pi offered plane_list_projects" => offered, "tool call reached Plane" => called,
           "forwarder added the key" => keyed, "result came back" => answered,
           "channels_send_message delivered on the host" => delivered }
checks.each { |name, ok| puts "#{ok ? "ok  " : "FAIL"} #{name}" }
exit(checks.values.all? ? 0 : 1)
