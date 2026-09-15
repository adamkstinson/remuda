# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "socket"
require "tmpdir"
require "remuda"

class ToolStepTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")

  def setup
    disconnect_db
    @tmpdir = Dir.mktmpdir("remuda-agent")
    @stub = start_mcp_stub
    write_tmp_agent
  end

  def teardown
    stop_mcp_stub
    disconnect_db
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  # Break this catches: Remuda.tool does not call MCP through the gem and
  # write a workflow_steps row of kind tool.
  def test_tool_call_writes_workflow_steps_row
    record = Remuda::Runner.new(@tmpdir).run("call_tool", trigger: "manual")
    assert_equal "ok", record.status, record.exception_message

    step = Remuda::WorkflowStep.find_by(kind: "tool")
    refute_nil step, "expected a workflow_steps row with kind tool"
    assert_equal record.id, step.workflow_run_id
    assert_equal "stub.echo", step.name
  end

  # Break this catches: engine code copied into the agent directory.
  def test_tmp_agent_and_dummy_contain_no_engine_code
    [DUMMY, @tmpdir].each do |dir|
      %w[lib migrate image].each do |name|
        path = File.join(dir, name)
        refute File.exist?(path), "#{dir} must not contain #{name}/"
      end
    end
  end

  private

  def write_tmp_agent
    File.write(File.join(@tmpdir, "AGENTS.md"), "# tmp\n")
    File.write(File.join(@tmpdir, "mcp.json"), JSON.generate(
      "mcpServers" => { "stub" => { "url" => "http://127.0.0.1:#{@stub[:port]}" } }
    ))
    FileUtils.mkdir_p(File.join(@tmpdir, ".remuda", "workflows"))
    FileUtils.mkdir_p(File.join(@tmpdir, ".remuda", "db"))
    File.write(File.join(@tmpdir, ".remuda", "workflows", "call_tool.rb"), <<~RUBY)
      Remuda.tool("stub.echo", message: "hi")
    RUBY
  end

  def start_mcp_stub
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        client = server.accept
        handle_mcp_client(client)
      rescue IOError, Errno::EBADF
        break
      end
    end
    { server: server, thread: thread, port: port }
  end

  def handle_mcp_client(client)
    headers = +""
    while (line = client.gets)
      break if line == "\r\n" || line == "\n"

      headers << line
    end
    length = headers[/Content-Length:\s*(\d+)/i, 1].to_i
    body = length.positive? ? client.read(length) : "{}"
    payload = JSON.parse(body)
    result = {
      "jsonrpc" => "2.0",
      "id" => payload["id"],
      "result" => { "echo" => payload.dig("params", "arguments") }
    }
    data = JSON.generate(result)
    client.write(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
      "Content-Length: #{data.bytesize}\r\nConnection: close\r\n\r\n#{data}"
    )
  ensure
    client.close
  end

  def stop_mcp_stub
    return unless @stub

    @stub[:server].close
    @stub[:thread].kill
  rescue IOError
    nil
  end

  def disconnect_db
    return unless defined?(ActiveRecord::Base)
    return unless ActiveRecord::Base.connected?

    ActiveRecord::Base.remove_connection
  end
end
