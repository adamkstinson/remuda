# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

# .remuda/mounts.yml: extra host paths bound under /work/<name>.
class MountsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("remuda-work")
    @dir = File.join(@root, "Agents", "ops")
    FileUtils.mkdir_p(File.join(@dir, ".remuda", "workflows"))
    FileUtils.mkdir_p(File.join(@root, "Products", "core"))
    FileUtils.mkdir_p(File.join(@root, "Docs"))
    File.write(File.join(@root, "index.yml"), "client: x\n")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def mounts(yaml)
    File.write(File.join(@dir, ".remuda", "mounts.yml"), yaml)
    Remuda::Mounts.for(@dir)
  end

  def test_no_file_means_no_mounts
    assert_equal [], Remuda::Mounts.for(@dir)
  end

  def test_paths_resolve_relative_to_the_agent_dir_under_work
    binds = mounts("core: ../../Products/core\ndocs: ../../Docs:ro\nindex.yml: ../../index.yml:ro\n")
    assert_equal [
      "#{@root}/Products/core:/work/core:rw",
      "#{@root}/Docs:/work/docs:ro",
      "#{@root}/index.yml:/work/index.yml:ro"
    ], binds
  end

  def test_missing_host_path_is_an_error
    err = assert_raises(ArgumentError) { mounts("core: ../../Products/nope\n") }
    assert_match(/does not exist/, err.message)
  end

  def test_bad_mode_and_bad_name_are_errors
    assert_raises(ArgumentError) { mounts("core: ../../Products/core:rx\n") }
    assert_raises(ArgumentError) { mounts("a/b: ../../Docs\n") }
    assert_raises(ArgumentError) { mounts("- ../../Docs\n") }
  end

  def test_sandbox_specs_include_the_mounts
    mounts("core: ../../Products/core\n")
    prompt = File.join(@dir, "prompt.txt")
    File.write(prompt, "hi")
    batch = Remuda::Sandbox.batch_spec(@dir, prompt_path: prompt).dig("HostConfig", "Binds")
    interactive = Remuda::Sandbox.interactive_spec(@dir).dig("HostConfig", "Binds")
    assert_includes batch, "#{@root}/Products/core:/work/core:rw"
    assert_includes interactive, "#{@root}/Products/core:/work/core:rw"
    assert_includes Remuda::Sandbox.attach_args(@dir), "#{@root}/Products/core:/work/core:rw"
  end
end
