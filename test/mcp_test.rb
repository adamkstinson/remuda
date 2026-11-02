# frozen_string_literal: true

require "test_helper"
require "remuda"

class McpTest < Minitest::Test
  SPEC = {
    "url" => "http://127.0.0.1:8121/mcp",
    "tailscale_url" => "http://mcp.example.test:8121/mcp"
  }.freeze

  def test_host_url_rewrites_docker_internal_for_host_calls
    url = "http://host.docker.internal:8121/mcp"
    assert_equal "http://127.0.0.1:8121/mcp", Remuda::Mcp.host_url(url)
  end

  def test_host_url_leaves_other_hosts_alone
    url = "https://mcp.example.test/mcp"
    assert_equal url, Remuda::Mcp.host_url(url)
  end

  def test_resolve_url_uses_tailscale_off_the_server
    ENV["REMUDA_LOCAL_HOSTNAME"] = "box"
    ENV["REMUDA_HOSTNAME"] = "laptop"
    assert_equal SPEC["tailscale_url"], Remuda::Mcp.resolve_url(SPEC)
  ensure
    ENV.delete("REMUDA_HOSTNAME")
    ENV.delete("REMUDA_LOCAL_HOSTNAME")
  end

  def test_resolve_url_fills_placeholders_from_vars_then_env
    ENV["REMUDA_TEST_APP_PORT"] = "3000"
    spec = { "url" => "${REMUDA_TEST_APP_URL}:${REMUDA_TEST_APP_PORT}/mcp" }
    assert_equal "http://127.0.0.1:3000/mcp",
                 Remuda::Mcp.resolve_url(spec, vars: { "REMUDA_TEST_APP_URL" => "http://127.0.0.1" })
  ensure
    ENV.delete("REMUDA_TEST_APP_PORT")
  end

  def test_resolve_url_with_an_unset_placeholder_is_nil
    assert_nil Remuda::Mcp.resolve_url({ "url" => "${REMUDA_TEST_NOT_SET}/mcp" })
  end

  def test_resolve_url_uses_local_when_hostname_matches
    ENV["REMUDA_LOCAL_HOSTNAME"] = "box"
    ENV["REMUDA_HOSTNAME"] = "box"
    assert_equal SPEC["url"], Remuda::Mcp.resolve_url(SPEC)
  ensure
    ENV.delete("REMUDA_HOSTNAME")
    ENV.delete("REMUDA_LOCAL_HOSTNAME")
  end
end
