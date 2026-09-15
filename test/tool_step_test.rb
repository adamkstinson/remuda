# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "socket"
require "remuda"

class ToolStepTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")
  DB = File.join(DUMMY, ".remuda/db/remuda.sqlite3")
  SCRIPT = File.join(DUMMY, ".remuda/workflows/call_tool.rb")
  MCP = File.join(DUMMY, "mcp.json")

  def setup
    disconnect_db
    FileUtils.rm_f(Dir.glob("#{DB}*"))
    @mcp_backup = File.file?(MCP) ? File.read(MCP) : nil
    @stub = start_mcp_stub
    File.write(MCP, JSON.generate(
      "mcpServers" => { "stub" => { "url" => "http://127.0.0.1:#{@stub[:port]}" } }
    ))
  end

  def teardown
    stop_mcp_stub
    disconnect_db
    FileUtils.rm_f(Dir.glob("#{DB}*"))
    if @mcp_backup
      File.write(MCP, @mcp_backup)
    elsif MCP && File.file?(MCP)
      File.delete(MCP)
    end
  end

  # Break this catches: tool step is recorded somewhere other than dummy SQLite.
  def test_dummy_tool_run_writes_workflow_steps_row
    assert File.file?(SCRIPT), "dummy needs .remuda/workflows/call_tool.rb"

    record = Remuda::Runner.new(DUMMY).run("call_tool", trigger: "manual")
    assert_equal "ok", record.status, record.exception_message
    assert File.file?(DB), "expected #{DB}"

    step = Remuda::WorkflowStep.find_by(kind: "tool")
    refute_nil step, "expected a workflow_steps row with kind tool in dummy SQLite"
    assert_equal record.id, step.workflow_run_id
    assert_equal "stub.echo", step.name
  end

  # Break this catches: engine code copied into the agent directory.
  def test_dummy_contains_no_engine_code
    %w[lib migrate image].each do |name|
      path = File.join(DUMMY, name)
      refute File.exist?(path), "dummy must not contain #{name}/"
    end
  end

  private

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
