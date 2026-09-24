# frozen_string_literal: true

require "test_helper"
require "remuda"

class McpTest < Minitest::Test
  SPEC = {
    "url" => "http://100.64.0.2:8121/mcp",
    "tailscale_url" => "http://adam-server.ts.adamkstinson.com:8121/mcp"
  }.freeze

  def test_host_url_rewrites_docker_internal_for_host_calls
    url = "http://host.docker.internal:8121/mcp"
    assert_equal "http://127.0.0.1:8121/mcp", Remuda::Mcp.host_url(url)
  end

  def test_host_url_leaves_other_hosts_alone
    url = "https://work.darkhorse.so/mcp"
    assert_equal url, Remuda::Mcp.host_url(url)
  end

  def test_resolve_url_uses_tailscale_off_the_server
    ENV["REMUDA_HOSTNAME"] = "omarchy"
    assert_equal SPEC["tailscale_url"], Remuda::Mcp.resolve_url(SPEC)
  ensure
    ENV.delete("REMUDA_HOSTNAME")
  end

  def test_resolve_url_uses_local_on_adam_server
    ENV["REMUDA_HOSTNAME"] = "adam-server"
    assert_equal SPEC["url"], Remuda::Mcp.resolve_url(SPEC)
  ensure
    ENV.delete("REMUDA_HOSTNAME")
  end
end
