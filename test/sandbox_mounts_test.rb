# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

# design/02-runner.md: .env and .remuda/ (db, bin, Gemfile) never enter the
# box; .remuda/workflows/ does, read-only for Remuda.agent.
class SandboxMountsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("remuda-mounts")
    FileUtils.mkdir_p(File.join(@dir, ".remuda", "workflows"))
    FileUtils.mkdir_p(File.join(@dir, ".remuda", "db"))
    File.write(File.join(@dir, ".env"), "PLANE_API_KEY=secret\n")
    @prompt = File.join(@dir, "prompt.txt")
    File.write(@prompt, "hi")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_batch_masks_env_and_remuda_and_mounts_workflows_read_only
    spec = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt)
    binds = spec.dig("HostConfig", "Binds")
    assert_includes binds, "/dev/null:/agent/.env:ro"
    assert_includes binds, "#{@dir}/.remuda/workflows:/agent/.remuda/workflows:ro"
    assert spec.dig("HostConfig", "Tmpfs").key?("/agent/.remuda"), "the rest of .remuda/ must be masked"
  end

  def test_interactive_masks_env_and_remuda_and_mounts_workflows_read_write
    spec = Remuda::Sandbox.interactive_spec(@dir)
    binds = spec.dig("HostConfig", "Binds")
    assert_includes binds, "/dev/null:/agent/.env:ro"
    assert_includes binds, "#{@dir}/.remuda/workflows:/agent/.remuda/workflows:rw"
    assert spec.dig("HostConfig", "Tmpfs").key?("/agent/.remuda")

    args = Remuda::Sandbox.attach_args(@dir)
    pairs = args.each_cons(2).to_a
    assert_includes pairs, ["-v", "/dev/null:/agent/.env:ro"]
    assert_includes pairs, ["-v", "#{@dir}/.remuda/workflows:/agent/.remuda/workflows:rw"]
    assert pairs.any? { |a, b| a == "--tmpfs" && b.start_with?("/agent/.remuda:") }, args.inspect
  end

  # Docker creates a missing mount target, and here that would be a
  # root-owned file in the operator's agent directory.
  def test_no_mask_for_an_env_that_does_not_exist
    File.delete(File.join(@dir, ".env"))
    binds = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt).dig("HostConfig", "Binds")
    refute binds.any? { |b| b.include?("/agent/.env") }, binds.inspect
  end

  # #48: the box loads only the per-run /agent/mcp.json. A host-side
  # .mcp.json or .pi/mcp.json (for pi on the host) holds real tokens and is
  # gitignored for that reason; inside the box it is only a readable secret.
  def test_masks_host_mcp_configs_in_both_modes
    write_host_mcp_configs
    batch = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt).dig("HostConfig", "Binds")
    interactive = Remuda::Sandbox.interactive_spec(@dir).dig("HostConfig", "Binds")
    [batch, interactive].each do |binds|
      assert_includes binds, "/dev/null:/agent/.mcp.json:ro"
      assert_includes binds, "/dev/null:/agent/.pi/mcp.json:ro"
    end

    pairs = Remuda::Sandbox.attach_args(@dir).each_cons(2).to_a
    assert_includes pairs, ["-v", "/dev/null:/agent/.mcp.json:ro"]
    assert_includes pairs, ["-v", "/dev/null:/agent/.pi/mcp.json:ro"]
  end

  def test_no_mask_for_host_mcp_configs_that_do_not_exist
    binds = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt).dig("HostConfig", "Binds")
    refute binds.any? { |b| b.include?("/agent/.mcp.json") || b.include?("/agent/.pi/mcp.json") }, binds.inspect
  end

  # Masks are file binds; they sit before the per-run copy so the rewrite at
  # /agent/mcp.json is untouched.
  def test_per_run_mcp_json_still_mounts_alongside_the_masks
    write_host_mcp_configs
    copy = File.join(@dir, "run-mcp.json")
    File.write(copy, "{}")
    binds = Remuda::Sandbox.batch_spec(@dir, prompt_path: @prompt, mcp_path: copy).dig("HostConfig", "Binds")
    assert_includes binds, "#{copy}:/agent/mcp.json:ro"
  end

  private

  def write_host_mcp_configs
    File.write(File.join(@dir, ".mcp.json"), '{"mcpServers":{"plane":{"headers":{"X-Plane-Key":"real"}}}}')
    FileUtils.mkdir_p(File.join(@dir, ".pi"))
    File.write(File.join(@dir, ".pi", "mcp.json"), '{"mcpServers":{}}')
  end
end
