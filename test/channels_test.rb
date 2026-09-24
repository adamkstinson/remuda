# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "timeout"
require "tmpdir"
require "remuda"
require_relative "support/fake_mattermost"

class ChannelsTest < Minitest::Test
  def with_agent(channels_yml: nil, env: nil)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".remuda"))
      File.write(File.join(dir, ".remuda/channels.yml"), channels_yml) if channels_yml
      File.write(File.join(dir, ".env"), env) if env
      yield dir
    end
  end

  # Break this catches: a fresh agent (commented-out template) failing to load.
  def test_no_bindings_is_an_empty_registry
    template = File.read(File.expand_path("../lib/remuda/templates/agent/.remuda/channels.yml", __dir__))
    with_agent(channels_yml: template) do |dir|
      registry = Remuda.channels(dir)
      assert registry.empty?
      assert_nil registry.send_message(jid: "mattermost:x", text: "hi")
      registry.start_all
    end
    with_agent { |dir| assert Remuda.channels(dir).empty? }
  end

  # Break this catches: the binding not reading the token from the agent's .env.
  def test_binds_mattermost_from_yaml_and_env
    yml = "transports:\n  mattermost:\n    url: https://chat.example\n    token_env: MM_BOT\n    allow: [adam]\n"
    with_agent(channels_yml: yml, env: "MM_BOT=secret\n") do |dir|
      registry = Remuda.channels(dir)
      channel = registry.get("mattermost")
      assert_instance_of Remuda::Channels::Mattermost, channel
      assert_same channel, registry.for_jid("mattermost:abc")
      assert_nil registry.for_jid("12345")
      assert_equal ["mattermost"], registry.names
    end
  end

  def test_missing_token_and_unknown_transport_fail_loudly
    yml = "transports:\n  mattermost:\n    url: https://chat.example\n"
    with_agent(channels_yml: yml) do |dir|
      error = assert_raises(ArgumentError) { Remuda.channels(dir) }
      assert_match(/MATTERMOST_TOKEN/, error.message)
    end
    with_agent(channels_yml: "transports:\n  carrier_pigeon: {}\n") do |dir|
      error = assert_raises(ArgumentError) { Remuda.channels(dir) }
      assert_match(/carrier_pigeon.*mattermost/, error.message)
    end
  end

  # Break this catches: registry routing replies to the wrong transport.
  def test_registry_routes_by_jid_and_fans_in_on_message
    server = FakeMattermost.new
    yml = "transports:\n  mattermost:\n    url: #{server.url}\n"
    with_agent(channels_yml: yml, env: "MATTERMOST_TOKEN=tok\n") do |dir|
      registry = Remuda.channels(dir)
      inbox = Queue.new
      registry.on_message { |msg| inbox << msg }
      registry.start_all
      server.socket
      server.push(FakeMattermost.posted(id: "p1", message: "hi", channel_type: "D", channel_id: "dm-7"))
      msg = Timeout.timeout(3) { inbox.pop }

      assert_equal "p1", registry.send_message(jid: msg.jid, text: "hello", thread_id: msg.thread_id)
      assert_equal "dm-7", Timeout.timeout(2) { server.posts.pop }["channel_id"]
    ensure
      registry&.stop_all
      server.close
    end
  end
end
