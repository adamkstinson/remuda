# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

class InteractiveTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DUMMY = File.join(ROOT, "test/dummy")

  def test_bare_remuda_spec_uses_same_image_as_agent
    spec = Remuda::Sandbox.interactive_spec(DUMMY)
    assert_equal Remuda::Image.tag, spec["Image"]
    assert_equal ["pi"], spec["Entrypoint"]
  end

  def test_interactive_mounts_the_whole_directory
    spec = Remuda::Sandbox.interactive_spec(DUMMY)
    binds = spec.dig("HostConfig", "Binds") || []
    assert_includes binds, "#{DUMMY}:/agent:rw"
    refute binds.any? { |b| b.include?("/lib/remuda") }, "workflow Ruby stays on the host gem"
  end

  def test_interactive_gives_pi_a_writable_home
    spec = Remuda::Sandbox.interactive_spec(DUMMY)
    env = Array(spec["Env"])
    home = env.find { |e| e.start_with?("HOME=") }
    refute_nil home, "HOME must be set so Pi does not mkdir /.pi"
    refute_equal "HOME=/", home
    assert_includes env, "PI_CODING_AGENT_DIR=/agent/.pi/agent"
    tmpfs = spec.dig("HostConfig", "Tmpfs") || {}
    assert tmpfs.key?("/tmp"), "expected tmpfs on /tmp for HOME"
    refute tmpfs.key?("/agent/.pi/agent")
  end

  def test_interactive_does_not_pass_no_session
    spec = Remuda::Sandbox.interactive_spec(DUMMY)
    refute_includes Array(spec["Cmd"]), "--no-session"

    args = Remuda::Sandbox.attach_args(DUMMY)
    refute_includes args, "--no-session"
    assert args.include?("PI_CODING_AGENT_DIR=/agent/.pi/agent") ||
           args.each_cons(2).any? { |a, b| a == "-e" && b == "PI_CODING_AGENT_DIR=/agent/.pi/agent" }
    assert File.directory?(File.join(DUMMY, ".pi", "agent", "sessions"))
  end

  def test_batch_agent_still_passes_no_session
    Dir.mktmpdir("prompt") do |dir|
      prompt = File.join(dir, "prompt.txt")
      File.write(prompt, "hi")
      spec = Remuda::Sandbox.batch_spec(DUMMY, prompt_path: prompt)
      assert_includes spec["Cmd"], "--no-session"
    end
  end

  def test_sandbox_adds_host_docker_internal
    spec = Remuda::Sandbox.interactive_spec(DUMMY)
    assert_includes spec.dig("HostConfig", "ExtraHosts"), "host.docker.internal:host-gateway"
    assert_includes spec.dig("HostConfig", "ExtraHosts"), "host.example.test:127.0.0.1"

    args = Remuda::Sandbox.attach_args(DUMMY)
    assert args.each_cons(2).any? { |a, b|
      a == "--add-host" && b == "host.docker.internal:host-gateway"
    }, args.inspect
    assert args.each_cons(2).any? { |a, b|
      a == "--add-host" && b == "host.example.test:127.0.0.1"
    }, args.inspect

    Dir.mktmpdir("prompt") do |dir|
      prompt = File.join(dir, "prompt.txt")
      File.write(prompt, "hi")
      batch = Remuda::Sandbox.batch_spec(DUMMY, prompt_path: prompt)
      assert_includes batch.dig("HostConfig", "ExtraHosts"), "host.docker.internal:host-gateway"
    end
  end

  def test_cli_bare_invokes_sandbox_attach
    source = File.read(File.join(ROOT, "lib/remuda/cli.rb"))
    assert_match(/Sandbox\.attach/, source)
  end

  def test_dummy_contains_no_engine_code
    %w[lib migrate image].each do |name|
      refute File.exist?(File.join(DUMMY, name)), "dummy must not contain #{name}/"
    end
  end
end
