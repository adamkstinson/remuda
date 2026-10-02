# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "net/http"
require "socket"
require "timeout"
require "tmpdir"
require "remuda"

class McpForwarderTest < Minitest::Test
  BASE = "http://host.docker.internal:4000/tok"

  FIXTURE = {
    "settings" => { "toolPrefix" => "server" },
    "mcpServers" => {
      "plane" => {
        "url" => "https://work.example.com/mcp",
        "headers" => { "X-Plane-Key" => "{{PLANE_API_KEY}}" },
        "directTools" => true
      },
      "gmail" => {
        "url" => "https://gmailmcp.example.com/mcp/v1",
        "headers" => { "Authorization" => "Bearer {{GMAIL_MCP_TOKEN}}" }
      },
      "docs" => { "url" => "https://docs.example.com/mcp" },
      "empty" => { "url" => "https://empty.example.com/mcp", "headers" => {} },
      "broken" => {
        "url" => "https://broken.example.com/mcp",
        "headers" => { "X-Key" => "{{NOT_SET_ANYWHERE}}" }
      },
      "local" => { "command" => "node", "args" => ["server.js"] }
    }
  }.freeze

  def setup
    @saved_env = ENV.to_h.slice("GMAIL_MCP_TOKEN", "NOT_SET_ANYWHERE", "REMUDA_FORWARDER_BIND")
    ENV["GMAIL_MCP_TOKEN"] = "gmail-secret"
    ENV.delete("NOT_SET_ANYWHERE")
  end

  def teardown
    %w[GMAIL_MCP_TOKEN NOT_SET_ANYWHERE REMUDA_FORWARDER_BIND].each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
  end

  # --- the rewrite, without Docker ----------------------------------------

  def test_servers_with_declared_headers_point_at_the_forwarder_without_headers
    config, = plan
    plane = config.dig("mcpServers", "plane")
    assert_equal "#{BASE}/plane", plane["url"]
    refute plane.key?("headers")
    assert_equal true, plane["directTools"], "other keys are copied through"
    assert_equal "#{BASE}/gmail", config.dig("mcpServers", "gmail", "url")
    assert_equal({ "toolPrefix" => "server" }, config["settings"])
  end

  def test_servers_without_a_secret_keep_their_url
    config, routes = plan
    assert_equal "https://docs.example.com/mcp", config.dig("mcpServers", "docs", "url")
    assert_equal "https://empty.example.com/mcp", config.dig("mcpServers", "empty", "url")
    assert_equal({ "command" => "node", "args" => ["server.js"] }, config.dig("mcpServers", "local"))
    refute routes.key?("docs")
    refute routes.key?("empty")
    refute routes.key?("local")
  end

  def test_route_table_fills_headers_from_env_file_then_process_env
    _, routes = plan
    assert_equal "https://work.example.com/mcp", routes["plane"].upstream
    assert_equal({ "X-Plane-Key" => "plane-secret" }, routes["plane"].headers)
    assert_equal({ "Authorization" => "Bearer gmail-secret" }, routes["gmail"].headers)
  end

  def test_env_file_wins_over_process_env_like_remuda_tool
    _, routes = Remuda::McpForwarder.plan(FIXTURE, vars: { "PLANE_API_KEY" => "plane-secret", "GMAIL_MCP_TOKEN" => "from-file" }, base_url: BASE)
    assert_equal({ "Authorization" => "Bearer from-file" }, routes["gmail"].headers)
  end

  def test_a_missing_variable_is_named_and_never_filled_blank
    config, routes = plan
    assert_equal "#{BASE}/broken", config.dig("mcpServers", "broken", "url")
    assert_equal ["NOT_SET_ANYWHERE"], routes["broken"].missing
  end

  def test_the_agent_copy_holds_no_secret_and_no_placeholder
    config, = plan
    json = JSON.generate(config)
    refute_includes json, "plane-secret"
    refute_includes json, "gmail-secret"
    refute_includes json, "{{"
    refute_includes json, "work.example.com"
  end

  # --- the proxy -------------------------------------------------------------

  def test_proxy_injects_declared_headers_and_streams_the_response
    release = Queue.new
    seen = {}
    upstream = serve_upstream do |client, request|
      seen.merge!(request)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nMcp-Session-Id: s-1\r\n" \
                   "Transfer-Encoding: chunked\r\n\r\n")
      write_chunk(client, "data: first\n\n")
      release.pop
      write_chunk(client, "data: second\n\n")
      client.write("0\r\n\r\n")
    end

    route = Remuda::McpForwarder::Route.new(
      name: "plane", upstream: "http://127.0.0.1:#{upstream[:port]}/mcp",
      headers: { "X-Plane-Key" => "plane-secret" }, missing: []
    )
    forwarder = Remuda::McpForwarder.new({ "plane" => route }, token: "tok", bind: "127.0.0.1").start
    begin
      uri = URI("http://127.0.0.1:#{forwarder.port}/tok/plane?x=1")
      body = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")
      Net::HTTP.start(uri.host, uri.port, read_timeout: 5) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json, text/event-stream"
        request.body = body
        http.request(request) do |response|
          assert_equal "200", response.code
          assert_equal "s-1", response["Mcp-Session-Id"]
          chunks = []
          released = false
          Timeout.timeout(5) do
            response.read_body do |chunk|
              chunks << chunk
              next if released || !chunks.join.include?("first")

              # The upstream holds "second" until the client has "first":
              # a buffering forwarder deadlocks here and times out.
              released = true
              release << true
            end
          end
          assert_includes chunks.join, "data: first"
          assert_includes chunks.join, "data: second"
        end
      end
      assert_equal "/mcp?x=1", seen[:path]
      assert_equal "plane-secret", seen[:headers]["x-plane-key"]
      assert_equal body, seen[:body]
      refute_equal "127.0.0.1:#{forwarder.port}", seen[:headers]["host"]
    ensure
      forwarder.stop
      upstream[:server].close
    end
  end

  def test_proxy_answers_401_and_does_not_call_upstream_when_a_variable_is_missing
    hits = 0
    upstream = serve_upstream { |_c, _r| hits += 1 }
    route = Remuda::McpForwarder::Route.new(
      name: "broken", upstream: "http://127.0.0.1:#{upstream[:port]}/mcp",
      headers: {}, missing: ["NOT_SET_ANYWHERE"]
    )
    forwarder = Remuda::McpForwarder.new({ "broken" => route }, token: "tok", bind: "127.0.0.1").start
    begin
      response = Net::HTTP.post(URI("http://127.0.0.1:#{forwarder.port}/tok/broken"), "{}")
      assert_equal "401", response.code
      assert_includes response.body, "NOT_SET_ANYWHERE"
      assert_equal 0, hits
    ensure
      forwarder.stop
      upstream[:server].close
    end
  end

  def test_proxy_refuses_a_request_without_the_run_token
    forwarder = Remuda::McpForwarder.new({}, token: "tok", bind: "127.0.0.1").start
    begin
      response = Net::HTTP.post(URI("http://127.0.0.1:#{forwarder.port}/wrong/plane"), "{}")
      assert_equal "404", response.code
    ensure
      forwarder.stop
    end
  end

  # --- lifetime and the mounted file -----------------------------------------

  def test_open_mounts_a_secret_free_copy_and_leaves_the_host_file_alone
    with_agent do |dir|
      host_before = File.read(File.join(dir, "mcp.json"))
      port = nil
      Dir.mktmpdir do |tmp|
        Remuda::McpForwarder.open(dir, tmp) do |path, forwarder|
          port = forwarder.port
          mounted = File.read(path)
          refute_includes mounted, "plane-secret"
          refute_includes mounted, "{{"
          assert_match %r{\Ahttp://host\.docker\.internal:#{port}/[0-9a-f]{32}/plane\z},
                       JSON.parse(mounted).dig("mcpServers", "plane", "url")
        end
      end
      assert_equal host_before, File.read(File.join(dir, "mcp.json"))
      assert_raises(Errno::ECONNREFUSED) { TCPSocket.new("127.0.0.1", port) }
    end
  end

  def test_open_stops_the_forwarder_when_the_block_fails
    with_agent do |dir|
      port = nil
      Dir.mktmpdir do |tmp|
        assert_raises(RuntimeError) do
          Remuda::McpForwarder.open(dir, tmp) do |_path, forwarder|
            port = forwarder.port
            raise "container failed"
          end
        end
      end
      assert_raises(Errno::ECONNREFUSED) { TCPSocket.new("127.0.0.1", port) }
    end
  end

  def test_open_without_mcp_json_yields_nothing_to_mount
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |tmp|
        Remuda::McpForwarder.open(dir, tmp) { |path, forwarder| assert_nil path; assert_nil forwarder }
      end
    end
  end

  def test_batch_and_interactive_mount_the_rewritten_file_read_only
    Dir.mktmpdir do |tmp|
      prompt = File.join(tmp, "prompt.txt")
      mcp = File.join(tmp, "mcp.json")
      File.write(prompt, "hi")
      File.write(mcp, "{}")
      dummy = File.expand_path("dummy", __dir__)

      batch = Remuda::Sandbox.batch_spec(dummy, prompt_path: prompt, mcp_path: mcp)
      assert_includes batch.dig("HostConfig", "Binds"), "#{mcp}:/agent/mcp.json:ro"

      interactive = Remuda::Sandbox.interactive_spec(dummy, mcp_path: mcp)
      assert_includes interactive.dig("HostConfig", "Binds"), "#{mcp}:/agent/mcp.json:ro"
      args = Remuda::Sandbox.attach_args(dummy, mcp_path: mcp)
      assert args.each_cons(2).any? { |a, b| a == "-v" && b == "#{mcp}:/agent/mcp.json:ro" }, args.inspect
    end
  end

  private

  def plan
    Remuda::McpForwarder.plan(FIXTURE, vars: { "PLANE_API_KEY" => "plane-secret" }, base_url: BASE)
  end

  def with_agent
    ENV["REMUDA_FORWARDER_BIND"] = "127.0.0.1"
    Dir.mktmpdir("remuda-agent") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".remuda"))
      File.write(File.join(dir, ".env"), "PLANE_API_KEY=plane-secret\n")
      File.write(File.join(dir, "mcp.json"), JSON.pretty_generate(
        "mcpServers" => {
          "plane" => { "url" => "https://work.example.com/mcp", "headers" => { "X-Plane-Key" => "{{PLANE_API_KEY}}" } }
        }
      ))
      yield dir
    end
  end

  def serve_upstream(&handler)
    server = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |c|
          request_line = c.gets.to_s
          headers = {}
          while (line = c.gets) && line != "\r\n"
            key, value = line.split(":", 2)
            headers[key.strip.downcase] = value.strip
          end
          body = c.read(headers["content-length"].to_i)
          handler.call(c, { path: request_line.split[1], headers: headers, body: body })
        ensure
          c.close
        end
      rescue IOError, Errno::EBADF
        break
      end
    end
    { server: server, port: server.addr[1] }
  end

  def write_chunk(client, data)
    client.write("#{data.bytesize.to_s(16)}\r\n#{data}\r\n")
    client.flush
  end
end
