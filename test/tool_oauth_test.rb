# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "remuda"

# Remuda.tool on the host reaches an OAuth server with the adapter's stored
# token, the way it reaches a ${VAR} server with the .env value.
class ToolOAuthTest < Minitest::Test
  KEY = ["k" * 32].pack("m0")

  def setup
    @dir = Dir.mktmpdir("remuda-agent")
    File.write(File.join(@dir, ".env"), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=#{KEY}\n")
    File.write(File.join(@dir, ".mcp.json"), JSON.generate(
      "mcpServers" => { "gmail" => { "url" => "https://gmailmcp.example.com/mcp/v1", "auth" => "oauth" } }
    ))
    @original_call = Remuda::Mcp.method(:call)
    @calls = []
    calls = @calls
    Remuda::Mcp.define_singleton_method(:call) do |url, name, args, token: nil, headers: {}|
      calls << { url: url, name: name, token: token, headers: headers }
      { "ok" => true }
    end
  end

  def teardown
    Remuda::Mcp.define_singleton_method(:call, @original_call)
    FileUtils.rm_rf(@dir)
  end

  def test_tool_sends_the_stored_oauth_token
    Remuda::McpOAuth.write(@dir, "gmail", {
      "tokens" => { "accessToken" => "stored-access", "expiresAt" => Time.now.to_i + 3600 }
    })
    Dir.chdir(@dir) { Remuda.tool("gmail.search_threads", query: "x") }
    assert_equal({ "Authorization" => "Bearer stored-access" }, @calls.last[:headers])
    assert_equal "https://gmailmcp.example.com/mcp/v1", @calls.last[:url]
  end

  def test_tool_fails_closed_when_the_server_is_not_connected
    error = assert_raises(Remuda::McpOAuth::Unavailable) do
      Dir.chdir(@dir) { Remuda.tool("gmail.search_threads", query: "x") }
    end
    assert_includes error.message, "/mcp-auth gmail"
    assert_empty @calls
  end
end
