# frozen_string_literal: true

require "test_helper"
require "remuda"

# A unix-socket hiccup talking to dockerd (seen in production as a bare
# JSON::ParserError on an empty response body, and as
# Docker::Error::TimeoutError) used to fail the whole channel reply with no
# recovery. Sandbox.run now retries a short, fixed list of transient errors
# before giving up.
class SandboxRetryTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")

  FakeContainer = Struct.new(:log_text) do
    def start = self
    def wait(_seconds) = { "StatusCode" => 0 }
    def logs(**) = log_text
    def delete(**) = true
  end

  def test_a_transient_docker_error_is_retried_and_the_run_still_succeeds
    attempts = 0
    with_fake_create(->(n) {
      attempts = n
      raise JSON::ParserError, "unexpected end of input at line 1 column 1" if n < 2

      FakeContainer.new(sample_jsonl)
    }) do
      with_no_sleep do
        result = Remuda::Sandbox.run(DUMMY, "hi")
        assert result.ok
        assert_equal "done", result.output
        assert_equal 2, attempts
      end
    end
  end

  def test_a_persistent_docker_error_is_raised_after_the_retry_budget
    attempts = 0
    with_fake_create(->(n) { attempts = n; raise Docker::Error::TimeoutError, "read timeout reached" }) do
      with_no_sleep do
        assert_raises(Docker::Error::TimeoutError) { Remuda::Sandbox.run(DUMMY, "hi") }
      end
    end
    assert_equal Remuda::Sandbox::MAX_ATTEMPTS, attempts
  end

  def test_a_non_retryable_error_is_not_retried
    attempts = 0
    with_fake_create(->(n) { attempts = n; raise ArgumentError, "bad spec" }) do
      with_no_sleep do
        assert_raises(ArgumentError) { Remuda::Sandbox.run(DUMMY, "hi") }
      end
    end
    assert_equal 1, attempts
  end

  private

  def sample_jsonl
    JSON.generate(
      "type" => "message_end",
      "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "done" }] }
    )
  end

  # Docker::Container.create is a class method on a gem class; redefine it
  # for the life of the block and put it back. Avoids depending on
  # minitest-mock, which this minitest version does not ship.
  def with_fake_create(factory)
    n = 0
    original = Docker::Container.method(:create)
    Docker::Container.define_singleton_method(:create) do |*_args|
      n += 1
      factory.call(n)
    end
    yield
  ensure
    Docker::Container.define_singleton_method(:create, original)
  end

  def with_no_sleep
    original = Kernel.instance_method(:sleep)
    Kernel.define_method(:sleep) { |*_args| 0 }
    yield
  ensure
    Kernel.define_method(:sleep, original)
  end
end
