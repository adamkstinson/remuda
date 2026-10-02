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
end
