# frozen_string_literal: true

require "test_helper"
require "remuda"

class ImageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DOCKERFILE = File.join(ROOT, "image/Dockerfile")

  def test_dockerfile_exists
    assert File.file?(DOCKERFILE), "expected image/Dockerfile"
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
    assert_match(/ENTRYPOINT/i, text)
  end
end
