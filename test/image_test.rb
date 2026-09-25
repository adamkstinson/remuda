# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

class ImageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DOCKERFILE = File.join(ROOT, "image/Dockerfile")
  CODING = File.join(ROOT, "image/Dockerfile.coding")

  def test_dockerfile_exists
    assert File.file?(DOCKERFILE), "expected image/Dockerfile"
    assert File.file?(CODING), "expected image/Dockerfile.coding"
  end

  def test_image_tag_is_stable_not_gem_version
    assert_equal "remuda-pi:latest", Remuda::Image.tag
    refute_includes Remuda::Image.tag, Remuda::VERSION
  end

  def test_image_is_pi_not_a_runtime_matrix
    text = File.read(DOCKERFILE)
    assert_match(/\bpi\b/i, text)
    refute_match(/\bclaude\b/i, text)
    refute_match(/\bopencode\b/i, text)
    refute_match(/\bcodex\b/i, text)
    refute_match(/\bgh\b/, text)
    assert_match(/ENTRYPOINT/i, text)
  end

  def test_coding_image_has_gh_and_ruby_and_pi
    text = File.read(CODING)
    assert_match(/\bpi\b/i, text)
    assert_match(/\bgh\b/, text)
    assert_match(/ruby:4\.0\.6/, text)
    refute_match(/\bclaude\b/i, text)
    assert_equal "remuda-coding:latest", Remuda::Image.coding_tag
  end

  def test_dummy_uses_pi_image
    dummy = File.join(ROOT, "test/dummy")
    assert_equal Remuda::Image.tag, Remuda::Image.for(dummy)
  end

  def test_poll_and_execute_does_not_pick_the_image
    Dir.mktmpdir("coding-agent") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".remuda/workflows"))
      File.write(File.join(dir, ".remuda/workflows/poll-and-execute.rb"), "# tick\n")
      assert_equal Remuda::Image.tag, Remuda::Image.for(dir)
    end
  end

  def test_remuda_image_file_selects_the_tag
    Dir.mktmpdir("coding-agent") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".remuda"))
      File.write(File.join(dir, ".remuda/image"), "remuda-coding:latest\n")
      assert_equal Remuda::Image.coding_tag, Remuda::Image.for(dir)
      spec = Remuda::Sandbox.interactive_spec(dir)
      assert_equal Remuda::Image.coding_tag, spec["Image"]

      File.write(File.join(dir, ".env"), "GH_TOKEN=ghs_test_not_a_real_token\n")
      spec = Remuda::Sandbox.interactive_spec(dir)
      assert_includes Array(spec["Env"]), "GH_TOKEN=ghs_test_not_a_real_token"
      binds = spec.dig("HostConfig", "Binds") || []
      refute binds.any? { |b| b.include?(".env") }
    end
  end
end
