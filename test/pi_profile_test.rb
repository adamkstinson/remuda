# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# The image ships Remuda's Pi profile: a `pi` first on PATH that loads the
# MCP client and points it at the agent's .mcp.json.
class PiProfileTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SHIM = File.join(ROOT, "image/pi-profile/pi")
  PI_VERSION = "@earendil-works/pi-coding-agent@1.3.0"
  ADAPTER = "pi-mcp-adapter@5.4.0"

  def test_both_images_install_pi_and_the_mcp_client_and_put_the_profile_first_on_path
    %w[image/Dockerfile image/Dockerfile.coding].each do |file|
      text = File.read(File.join(ROOT, file))
      assert_includes text, "npm install -g --ignore-scripts #{PI_VERSION}", file
      assert_includes text, "npm install -g --ignore-scripts #{ADAPTER}", file
      assert_includes text, "COPY pi-profile/pi /opt/remuda/bin/pi", file
      assert_includes text, "COPY pi-profile/darkhorse.ts /opt/remuda/pi-profile/darkhorse.ts", file
      assert_includes text, "COPY pi-profile/no-mcp.json /opt/remuda/pi-profile/no-mcp.json", file
      assert_match(%r{^ENV PATH=/opt/remuda/bin:\$PATH$}, text, file)
    end
  end

  def test_profile_reads_the_mount_named_by_remuda_mcp_config
    with_shim(mcp_config: :agent) do |run|
      out = run.call("--mode", "json", "--print")
      assert_equal "-e /adapter -e /darkhorse.ts --no-mcp --mcp-config AGENT/.mcp.json --mode json --print", out[:args]
      assert_equal "exclusive", out[:mode]
    end
  end

  def test_profile_reads_the_fallback_copy_when_the_agent_has_no_project_file
    with_shim(mcp_config: :run) do |run|
      out = run.call("--print")
      assert_equal "-e /adapter -e /darkhorse.ts --no-mcp --mcp-config RUN/mcp.json --print", out[:args]
      assert_equal "exclusive", out[:mode]
    end
  end

  # Without the env the profile must not read the agent's own .mcp.json: it
  # may hold literal secrets. It points the adapter at the image's empty
  # config instead. An explicit --mcp-config is also what keeps
  # pi-mcp-adapter 5.4 from adding "-builtin:mcp" to the agent's tracked
  # .pi/agent/settings.json on first start (#64).
  def test_profile_without_the_env_reads_the_images_empty_config
    with_shim(mcp_config: nil) do |run|
      out = run.call("--print")
      assert_equal "-e /adapter -e /darkhorse.ts --no-mcp --mcp-config /no-mcp.json --print", out[:args]
      assert_equal "exclusive", out[:mode]
    end
  end

  def test_profile_with_the_env_naming_a_missing_file_reads_the_images_empty_config
    with_shim(mcp_config: "/nonexistent/mcp.json") do |run|
      out = run.call("--print")
      assert_equal "-e /adapter -e /darkhorse.ts --no-mcp --mcp-config /no-mcp.json --print", out[:args]
      assert_equal "exclusive", out[:mode]
    end
  end

  def test_the_images_empty_config_declares_no_servers
    config = JSON.parse(File.read(File.join(ROOT, "image/pi-profile/no-mcp.json")))
    assert_equal({ "mcpServers" => {} }, config)
  end

  def test_profile_passes_pi_subcommands_through_untouched
    with_shim(mcp_config: :agent) do |run|
      assert_equal "list", run.call("list")[:args]
      assert_equal "auth status", run.call("auth", "status")[:args]
    end
  end

  private

  # Run the real shim with its fixed paths pointed at a temp dir and a fake
  # pi that prints its argv and PI_MCP_CONFIG_MODE. REMUDA_MCP_CONFIG is what
  # the runner sets: the mounted project file, the fallback copy, or unset.
  def with_shim(mcp_config:)
    Dir.mktmpdir("pi-profile") do |dir|
      agent = File.join(dir, "agent")
      FileUtils.mkdir_p(agent)
      run_dir = File.join(dir, "run")
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(agent, ".mcp.json"), "{}")
      File.write(File.join(run_dir, "mcp.json"), "{}")
      fake = File.join(dir, "fake-pi")
      File.write(fake, "#!/bin/sh\necho \"$*\"\necho \"${PI_MCP_CONFIG_MODE:-}\"\n")
      File.chmod(0o755, fake)
      shim = File.join(dir, "pi")
      File.write(shim, File.read(SHIM)
        .gsub("/usr/local/bin/pi", fake)
        .gsub("/usr/local/lib/node_modules/pi-mcp-adapter", "/adapter")
        .gsub("/opt/remuda/pi-profile/darkhorse.ts", "/darkhorse.ts")
        .gsub("/opt/remuda/pi-profile/no-mcp.json", "/no-mcp.json"))
      File.chmod(0o755, shim)

      config = case mcp_config
      when :agent then File.join(agent, ".mcp.json")
      when :run then File.join(run_dir, "mcp.json")
      else mcp_config
      end
      run = lambda do |*args|
        stdout, status = Open3.capture2({ "REMUDA_MCP_CONFIG" => config, "PI_MCP_CONFIG_MODE" => nil }, shim, *args)
        assert status.success?
        lines = stdout.lines.map(&:chomp)
        { args: lines[0].sub(agent, "AGENT").sub(run_dir, "RUN"), mode: lines[1].to_s }
      end
      yield run
    end
  end
end
