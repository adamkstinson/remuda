# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "socket"
require "remuda"

class ToolsCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")
  EXE = File.join(ROOT, "exe/remuda")
  MCP = File.join(DUMMY, "mcp.json")
  ENV_FILE = File.join(DUMMY, ".env")

  def setup
    @mcp_backup = File.file?(MCP) ? File.read(MCP) : nil
    @env_backup = File.file?(ENV_FILE) ? File.read(ENV_FILE) : :missing
    @stub = start_mcp_stub
    File.write(MCP, JSON.generate(
      "mcpServers" => { "stub" => { "url" => "http://127.0.0.1:#{@stub[:port]}" } }
    ))
  end

  def teardown
    stop_mcp_stub
    if @mcp_backup
      File.write(MCP, @mcp_backup)
    elsif File.file?(MCP)
      File.delete(MCP)
    end
    if @env_backup == :missing
      FileUtils.rm_f(ENV_FILE)
    elsif @env_backup
      File.write(ENV_FILE, @env_backup)
    end
  end

  # Break this catches: remuda tools is not a CLI command that lists MCP tools.
  def test_remuda_tools_lists_qualified_tool_names
    status, output = invoke("tools", DUMMY)
    assert_equal 0, status, output
    assert_includes output, "stub.echo"
    assert_includes output, "Echo arguments"
  end

  # Break this catches: remuda tools TOOL_NAME does not print that tool's input schema.
  def test_remuda_tools_shows_one_tool_schema
    status, output = invoke("tools", DUMMY, "stub.echo")
    assert_equal 0, status, output
    assert_includes output, "stub.echo"
    assert_includes output, "Echo arguments"
    assert_includes output, "\"text\""
    assert_includes output, "\"required\""
  end

  # Break this catches: remuda tools silently ignores an unknown tool name.
  def test_remuda_tools_unknown_name_fails
    status, output = invoke("tools", DUMMY, "stub.missing")
    assert_equal 1, status, output
    assert_includes output, "unknown tool: stub.missing"
  end

  # Break this catches: remuda tools requires server.method and rejects the bare tool name.
  def test_remuda_tools_matches_bare_tool_name
    status, output = invoke("tools", DUMMY, "echo")
    assert_equal 0, status, output
    assert_includes output, "stub.echo"
    assert_includes output, "\"text\""
  end

  # Break this catches: remuda tools ignores mcp.json headers (so planet-mcp never sees X-Plane-Key).
  def test_remuda_tools_sends_interpolated_mcp_headers
    File.write(ENV_FILE, "PLANE_API_KEY=from-env-key\n")
    File.write(MCP, JSON.generate(
      "mcpServers" => {
        "stub" => {
          "url" => "http://127.0.0.1:#{@stub[:port]}",
          "headers" => { "X-Plane-Key" => "{{PLANE_API_KEY}}" }
        }
      }
    ))

    status, output = invoke("tools", DUMMY)
    assert_equal 0, status, output
    sent = @stub[:seen_headers].join
    assert_includes sent, "from-env-key"
  end

  private

  def invoke(*args)
    env = { "RUBYLIB" => File.join(ROOT, "lib") }
    stdout, stderr, status = Open3.capture3(env, Gem.ruby, EXE, *args)
    [status.exitstatus, stderr.empty? ? stdout : "#{stdout}\n#{stderr}"]
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
    { server: server, thread: thread, port: port, seen_headers: [] }
  end

  def handle_mcp_client(client)
    headers = +""
    while (line = client.gets)
      break if line == "\r\n" || line == "\n"

      headers << line
    end
    @stub[:seen_headers] << headers if @stub
    length = headers[/Content-Length:\s*(\d+)/i, 1].to_i
    body = length.positive? ? client.read(length) : "{}"
    payload = JSON.parse(body)
    result =
      if payload["method"] == "tools/list"
        {
          "jsonrpc" => "2.0",
          "id" => payload["id"],
          "result" => {
            "tools" => [
              {
                "name" => "echo",
                "description" => "Echo arguments",
                "inputSchema" => {
                  "type" => "object",
                  "properties" => { "text" => { "type" => "string" } },
                  "required" => ["text"]
                }
              }
            ]
          }
        }
      else
        {
          "jsonrpc" => "2.0",
          "id" => payload["id"],
          "error" => { "message" => "unexpected #{payload["method"]}" }
        }
      end
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
end
