# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "remuda"

# session_for / bind_thread: the (jid, thread_id) -> Pi session mapping.
class ChannelThreadsTest < Minitest::Test
  def setup
    disconnect_db
    @dir = Dir.mktmpdir("remuda-threads")
    FileUtils.mkdir_p(File.join(@dir, ".remuda"))
  end

  def teardown
    disconnect_db
    FileUtils.rm_rf(@dir)
  end

  # Break this catches: a thread gets a new session on every message.
  def test_session_for_mints_and_reuses_one_session_per_thread
    first = registry.session_for(jid: "mattermost:c1", thread_id: "t1")
    second = registry.session_for(jid: "mattermost:c1", thread_id: "t1")

    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, first)
    assert_equal first, second
  end

  # Break this catches: two threads sharing a session.
  def test_different_threads_get_different_sessions
    a = registry.session_for(jid: "mattermost:c1", thread_id: "t1")
    b = registry.session_for(jid: "mattermost:c1", thread_id: "t2")

    refute_equal a, b
  end

  def test_session_for_accepts_an_incoming_message_and_stores_its_channel
    message = Remuda::Channels::IncomingMessage.new(
      jid: "mattermost:c1", channel: "mattermost", text: "hi",
      sender_name: "adam", thread_id: "t1"
    )
    session_id = registry.session_for(message)

    row = Remuda::ChannelThread.find_by(jid: "mattermost:c1", thread_id: "t1")
    assert_equal session_id, row.session_id
    assert_equal "mattermost", row.channel
  end

  # Break this catches: a live thread looking stale because the clock never moves.
  def test_session_for_touches_last_message_at
    session_id = registry.session_for(jid: "mattermost:c1", thread_id: "t1")
    row = Remuda::ChannelThread.find_by(jid: "mattermost:c1", thread_id: "t1")
    row.update!(last_message_at: Time.now.utc - 3600)

    registry.session_for(jid: "mattermost:c1", thread_id: "t1")

    assert_operator row.reload.last_message_at, :>, Time.now.utc - 60
    assert_equal session_id, row.session_id
  end

  def test_bind_thread_then_session_for_returns_the_bound_id
    bound = "11111111-2222-3333-4444-555555555555"
    row = registry.bind_thread(jid: "mattermost:c1", thread_id: "t1", session_id: bound)

    assert_instance_of Remuda::ChannelThread, row
    assert_equal bound, registry.session_for(jid: "mattermost:c1", thread_id: "t1")
  end

  # Break this catches: an explicit rebind being ignored.
  def test_bind_thread_overwrites_an_existing_binding
    registry.bind_thread(jid: "mattermost:c1", thread_id: "t1", session_id: "aaaaaaaa-0000-0000-0000-000000000000")
    registry.bind_thread(jid: "mattermost:c1", thread_id: "t1", session_id: "bbbbbbbb-0000-0000-0000-000000000000")

    assert_equal "bbbbbbbb-0000-0000-0000-000000000000",
                 registry.session_for(jid: "mattermost:c1", thread_id: "t1")
    assert_equal 1, Remuda::ChannelThread.where(jid: "mattermost:c1", thread_id: "t1").count
  end

  # The mapping survives a new registry (a restart), not just one object.
  def test_the_binding_persists_across_registry_instances
    first = registry.session_for(jid: "mattermost:c1", thread_id: "t1")

    assert_equal first, fresh_registry.session_for(jid: "mattermost:c1", thread_id: "t1")
  end

  private

  def registry
    @registry ||= build_registry
  end

  def fresh_registry
    build_registry
  end

  def build_registry
    reg = Remuda::Channels::Registry.new(agent_dir: @dir)
    reg.register(FakeMattermost.new)
    reg
  end

  def disconnect_db
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
  end

  # Just enough transport for for_jid to resolve the "mattermost:" prefix.
  class FakeMattermost < Remuda::Channels::Channel
    def name = "mattermost"
    def owns_jid?(jid) = jid.to_s.start_with?("mattermost:")
  end
end
