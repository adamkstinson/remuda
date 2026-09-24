# frozen_string_literal: true

require "test_helper"
require "remuda"

class McpTest < Minitest::Test
  def test_host_url_rewrites_docker_internal_for_host_calls
    url = "http://host.docker.internal:8121/mcp"
    assert_equal "http://127.0.0.1:8121/mcp", Remuda::Mcp.host_url(url)
  end

  def test_host_url_leaves_other_hosts_alone
    url = "https://mcp.example.com/mcp"
    assert_equal url, Remuda::Mcp.host_url(url)
  end
end
