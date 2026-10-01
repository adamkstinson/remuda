# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

# The image ships Remuda's Pi profile: a `pi` first on PATH that loads the
# MCP client and points it at the agent's mcp.json.
class PiProfileTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SHIM = File.join(ROOT, "image/pi-profile/pi")
  ADAPTER = "pi-mcp-adapter@4.0.0"

  def test_both_images_install_the_mcp_client_and_put_the_profile_first_on_path
    %w[image/Dockerfile image/Dockerfile.coding].each do |file|
      text = File.read(File.join(ROOT, file))
      assert_includes text, "npm install -g --ignore-scripts #{ADAPTER}", file
      assert_includes text, "COPY pi-profile/pi /opt/remuda/bin/pi", file
      assert_match(%r{^ENV PATH=/opt/remuda/bin:\$PATH$}, text, file)
    end
  end

  def test_profile_loads_the_client_and_reads_only_the_agents_mcp_json
    with_shim(mcp_json: true) do |run|
      out = run.call("--mode", "json", "--print")
      assert_equal "-e /adapter --mcp-config AGENT/mcp.json --mode json --print", out[:args]
      assert_equal "exclusive", out[:mode]
    end
  end

  def test_profile_without_mcp_json_still_loads_the_client
    with_shim(mcp_json: false) do |run|
      out = run.call("--print")
      assert_equal "-e /adapter --print", out[:args]
      assert_equal "", out[:mode]
    end
  end

  def test_profile_passes_pi_subcommands_through_untouched
    with_shim(mcp_json: true) do |run|
      assert_equal "list", run.call("list")[:args]
      assert_equal "auth status", run.call("auth", "status")[:args]
    end
  end

  private

  # Run the real shim with its fixed paths pointed at a temp dir and a fake
  # pi that prints its argv and PI_MCP_CONFIG_MODE.
  def with_shim(mcp_json:)
    Dir.mktmpdir("pi-profile") do |dir|
      agent = File.join(dir, "agent")
      FileUtils.mkdir_p(agent)
      File.write(File.join(agent, "mcp.json"), "{}") if mcp_json
      fake = File.join(dir, "fake-pi")
      File.write(fake, "#!/bin/sh\necho \"$*\"\necho \"${PI_MCP_CONFIG_MODE:-}\"\n")
      File.chmod(0o755, fake)
      shim = File.join(dir, "pi")
      File.write(shim, File.read(SHIM)
        .gsub("/usr/local/bin/pi", fake)
        .gsub("/usr/local/lib/node_modules/pi-mcp-adapter", "/adapter")
        .gsub("/agent/", "#{agent}/"))
      File.chmod(0o755, shim)

      run = lambda do |*args|
        stdout, status = Open3.capture2({ "PI_MCP_CONFIG_MODE" => nil }, shim, *args)
        assert status.success?
        lines = stdout.lines.map(&:chomp)
        { args: lines[0].sub(agent, "AGENT"), mode: lines[1].to_s }
      end
      yield run
    end
  end
end
