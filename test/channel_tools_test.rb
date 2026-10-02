# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "remuda"

class ChannelToolsTest < Minitest::Test
  # A transport that records what it was asked to send.
  class Recorder < Remuda::Channels::Channel
    SENT = []

    def self.from_config(_config, env)
      new(env)
    end

    def initialize(env)
      super()
      @env = env
    end

    def name = "recorder"
    def owns_jid?(jid) = jid.to_s.start_with?("rec:")

    def send_message(jid:, text:, thread_id: nil, files: nil)
      SENT << { jid: jid, text: text, thread_id: thread_id, files: files }
      thread_id || "root-1"
    end
  end
  Remuda::Channels.register_transport("recorder", Recorder)

  def setup
    Recorder::SENT.clear
    disconnect_db
    ENV["REMUDA_FORWARDER_BIND"] = "127.0.0.1"
    @dir = Dir.mktmpdir("remuda-channel-tools")
    FileUtils.mkdir_p(File.join(@dir, ".remuda", "workflows"))
    FileUtils.mkdir_p(File.join(@dir, "files"))
    File.write(File.join(@dir, ".remuda", "channels.yml"), "transports:\n  recorder: {}\n")
    File.write(File.join(@dir, ".env"), "MATTERMOST_TOKEN=bot-secret\n")
    File.write(File.join(@dir, "mcp.json"), JSON.generate("mcpServers" => {}))
    File.write(File.join(@dir, "files", "report.txt"), "hi")
  end

  def teardown
    ENV.delete("REMUDA_FORWARDER_BIND")
    disconnect_db
    FileUtils.rm_rf(@dir)
  end

  # --- workflow scripts ------------------------------------------------------

  def test_remuda_tool_sends_through_the_bound_channel_and_records_a_step
    run = start_run
    result = Remuda::Current.set(run: run, agent_dir: @dir) do
      Remuda.tool("channels.send_message", jid: "rec:town", text: "digest", thread_id: "t-1")
    end

    assert_equal [{ jid: "rec:town", text: "digest", thread_id: "t-1", files: nil }], Recorder::SENT
    assert_equal({ "thread_id" => "t-1" }, result)
    step = Remuda::WorkflowStep.find_by(kind: "tool")
    assert_equal "channels.send_message", step.name
    assert_equal "rec:town", step.input["jid"]
    assert_equal({ "thread_id" => "t-1" }, step.output)
  end

  def test_remuda_tool_raises_when_no_channel_owns_the_jid
    Remuda::Current.set(agent_dir: @dir) do
      error = assert_raises(RuntimeError) { Remuda.tool("channels.send_message", jid: "nope:1", text: "x") }
      assert_match(/nope:1/, error.message)
    end
  end

  def test_tools_lists_send_message_only_when_a_transport_is_bound
    names = Remuda.tools(@dir).map { |t| "#{t[:server]}.#{t[:name]}" }
    assert_equal ["channels.send_message"], names
    tool = Remuda.tools(@dir).first
    assert_equal %w[jid text], tool[:input_schema]["required"]

    File.write(File.join(@dir, ".remuda", "channels.yml"), "# transports:\n")
    assert_empty Remuda.tools(@dir)
  end

  # --- the sandboxed agent ---------------------------------------------------

  def test_the_agents_mcp_json_gets_a_channels_server_on_the_forwarder
    Dir.mktmpdir do |tmp|
      Remuda::McpForwarder.open(@dir, tmp, local: Remuda::ChannelsMcp.routes(@dir)) do |path, forwarder|
        entry = JSON.parse(File.read(path)).dig("mcpServers", "channels")
        assert_match %r{\Ahttp://host\.docker\.internal:#{forwarder.port}/[0-9a-f]{32}/channels\z}, entry["url"]
        refute_includes File.read(path), "bot-secret"
      end
    end
  end

  def test_an_agent_without_mcp_json_still_gets_channels
    File.delete(File.join(@dir, "mcp.json"))
    Dir.mktmpdir do |tmp|
      Remuda::McpForwarder.open(@dir, tmp, local: Remuda::ChannelsMcp.routes(@dir)) do |path, _forwarder|
        assert_equal ["channels"], JSON.parse(File.read(path))["mcpServers"].keys
      end
    end
  end

  def test_no_channels_server_without_bindings
    File.write(File.join(@dir, ".remuda", "channels.yml"), "")
    assert_empty Remuda::ChannelsMcp.routes(@dir)
  end

  def test_the_agent_calls_send_message_over_mcp_and_the_host_delivers
    run = start_run
    with_channels_server(run: run) do |call|
      init = call.call("initialize", { "protocolVersion" => "2025-06-18", "capabilities" => {} })
      assert_equal "2025-06-18", init.dig("result", "protocolVersion")
      assert init.dig("result", "capabilities", "tools")

      tools = call.call("tools/list", {})
      assert_equal ["send_message"], tools.dig("result", "tools").map { |t| t["name"] }

      sent = call.call("tools/call", { "name" => "send_message",
                                       "arguments" => { "jid" => "rec:dm", "text" => "done",
                                                        "files" => ["/agent/files/report.txt"] } })
      refute sent.dig("result", "isError")
      assert_equal({ "thread_id" => "root-1" }, JSON.parse(sent.dig("result", "content", 0, "text")))
    end

    assert_equal 1, Recorder::SENT.size
    assert_equal [File.join(File.realpath(@dir), "files", "report.txt")], Recorder::SENT.first[:files]
    step = Remuda::WorkflowStep.find_by(kind: "tool", name: "channels.send_message")
    refute_nil step, "the agent's send is a workflow step too"
    assert_equal run.id, step.workflow_run_id
  end

  def test_the_agent_cannot_attach_files_outside_its_directory_or_its_env
    File.symlink("/etc/hostname", File.join(@dir, "files", "escape"))
    with_channels_server do |call|
      ["/agent/.env", "/etc/passwd", "/agent/../etc/passwd", "/agent/files/escape", "/agent/.remuda/db/x"].each do |path|
        reply = call.call("tools/call", { "name" => "send_message",
                                          "arguments" => { "jid" => "rec:dm", "text" => "x", "files" => [path] } })
        assert reply.dig("result", "isError"), "#{path} must be refused"
      end
    end
    assert_empty Recorder::SENT
  end

  def test_a_failed_send_is_a_tool_error_not_a_crash
    with_channels_server do |call|
      reply = call.call("tools/call", { "name" => "send_message", "arguments" => { "jid" => "nope:1", "text" => "x" } })
      assert reply.dig("result", "isError")
      assert_match(/nope:1/, reply.dig("result", "content", 0, "text"))
    end
  end

  def test_the_bots_token_never_enters_the_container
    Dir.mktmpdir do |tmp|
      prompt = File.join(tmp, "prompt.txt")
      File.write(prompt, "hi")
      spec = Remuda::Sandbox.batch_spec(@dir, prompt_path: prompt)
      refute Array(spec["Env"]).any? { |e| e.include?("bot-secret") || e.start_with?("MATTERMOST") }, spec["Env"].inspect
    end
  end

  private

  def with_channels_server(run: nil)
    Dir.mktmpdir do |tmp|
      local = Remuda::ChannelsMcp.routes(@dir, run: run)
      Remuda::McpForwarder.open(@dir, tmp, local: local) do |path, _forwarder|
        url = URI(JSON.parse(File.read(path)).dig("mcpServers", "channels", "url").sub("host.docker.internal", "127.0.0.1"))
        id = 0
        call = lambda do |method, params|
          id += 1
          response = Net::HTTP.post(url, JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params),
                                    "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream")
          assert_equal "200", response.code, response.body
          JSON.parse(response.body)
        end
        yield call
      end
    end
  end

  def start_run
    Remuda::Db.connect(@dir)
    Remuda::WorkflowRun.create!(workflow: "w", status: "running", trigger: "manual", started_at: Time.now.utc)
  end

  def disconnect_db
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
  end
end
