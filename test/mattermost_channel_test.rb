# frozen_string_literal: true

require "test_helper"
require "stringio"
require "timeout"
require "remuda"
require_relative "support/fake_mattermost"

class MattermostChannelTest < Minitest::Test
  Posted = FakeMattermost.method(:posted)

  def setup
    @server = FakeMattermost.new
    @inbox = Queue.new
    @log = StringIO.new
  end

  def teardown
    @channel&.stop!
    @server.close
  end

  def channel(**opts)
    @channel = Remuda::Channels::Mattermost.new(
      url: @server.url, token: "tok", reconnect_delay: 0.05, logger: @log, **opts
    )
    @channel.on_message { |msg| @inbox << msg }
    @channel
  end

  def started(**opts)
    channel(**opts).start!
    @server.socket
    @channel
  end

  def next_message(timeout: 3)
    Timeout.timeout(timeout) { @inbox.pop }
  end

  def assert_nothing_delivered
    sleep 0.2
    assert @inbox.empty?, "expected no inbound, got #{@inbox.size}"
  end

  # Break this catches: websocket inbound never reaches on_message, or loses
  # the address a reply needs.
  def test_direct_message_arrives_with_reply_address
    started
    @server.push(Posted.(id: "p1", message: "status?", channel_id: "dm-1", channel_type: "D"))

    msg = next_message
    assert_equal "mattermost:dm-1", msg.jid
    assert_equal "mattermost", msg.channel
    assert_equal "status?", msg.text
    assert_equal "adam", msg.sender_name
    assert_equal "p1", msg.thread_id
    assert_equal "ops", msg.bot_token_key
    assert_equal "Bearer tok", @server.upgrade_headers["authorization"]
  end

  # Break this catches: the bot answering every line in a busy channel.
  def test_channel_post_needs_a_mention
    ch = channel
    ch.handle_event(Posted.(id: "p1", message: "lunch?"))
    ch.handle_event(Posted.(id: "p2", message: "ping", mentions: ["bot-id"]))
    ch.handle_event(Posted.(id: "p3", message: "hey @ops, look"))
    ch.handle_event(Posted.(id: "p4", message: "email ops@darkhorse.so or @opsy"))

    assert_equal %w[p2 p3], drain.map(&:thread_id)
  end

  # Break this catches: the bot talking to itself or to another bot forever.
  def test_ignores_self_system_and_bot_posts
    ch = channel
    ch.handle_event(Posted.(id: "p1", message: "@ops mine", user_id: "bot-id"))
    ch.handle_event(Posted.(id: "p2", message: "@ops joined", type: "system_join_channel"))
    ch.handle_event(Posted.(id: "p3", message: "@ops hi", props: { "from_bot" => "true" }))
    ch.handle_event(Posted.(id: "p4", message: "   ", channel_type: "D"))
    assert_empty drain
  end

  def test_allow_list_limits_senders
    ch = channel(allow: ["@adam"])
    ch.handle_event(Posted.(id: "p1", message: "hi", channel_type: "D", sender: "@mallory"))
    ch.handle_event(Posted.(id: "p2", message: "hi", channel_type: "D", sender: "@adam"))
    assert_equal ["p2"], drain.map(&:thread_id)
  end

  def test_thread_replies_follow_and_keep_the_root
    ch = channel
    ch.handle_event(Posted.(id: "r1", message: "and then?", root_id: "root", followers: ["bot-id"]))
    ch.handle_event(Posted.(id: "r2", message: "unrelated", root_id: "other", followers: ["u-x"]))
    assert_equal [["and then?", "root"]], drain.map { |m| [m.text, m.thread_id] }

    quiet = channel(follow_threads: false)
    quiet.handle_event(Posted.(id: "r3", message: "and then?", root_id: "root", followers: ["bot-id"]))
    assert_empty drain
  end

  def test_mentions_only_false_takes_everything_and_duplicates_once
    ch = channel(mentions_only: false)
    ch.handle_event(Posted.(id: "p1", message: "lunch?"))
    ch.handle_event(Posted.(id: "p1", message: "lunch?"))
    assert_equal ["p1"], drain.map(&:thread_id)
  end

  # Break this catches: replies landing outside the thread, or a new thread
  # returning nothing to continue it with.
  def test_send_message_posts_in_thread
    ch = channel
    assert_equal "root-1", ch.send_message(jid: "mattermost:ch-9", text: "done", thread_id: "root-1")
    post = Timeout.timeout(2) { @server.posts.pop }
    assert_equal({ "channel_id" => "ch-9", "message" => "done", "root_id" => "root-1" }, post)

    new_root = ch.send_message(jid: "mattermost:ch-9", text: "fresh")
    assert_equal "new-2", new_root
    refute Timeout.timeout(2) { @server.posts.pop }.key?("root_id")

    assert_nil ch.send_message(jid: "telegram:42", text: "no")
    assert ch.owns_jid?("mattermost:x")
    refute ch.owns_jid?("42")
  end

  def test_send_message_failure_returns_nil_and_logs
    @server.token = "other"
    assert_nil channel.send_message(jid: "mattermost:ch-9", text: "x")
    assert_match(/HTTP 401/, @log.string)
  end

  def test_bad_token_fails_at_start
    @server.token = "other"
    error = assert_raises(Remuda::Channels::Mattermost::Error) { channel.start! }
    assert_match(/401/, error.message)
    refute @channel.running?
  end

  # Break this catches: a dropped socket silently dropping messages.
  def test_reconnects_and_backfills_what_it_missed
    started
    @server.push(Posted.(id: "p1", message: "first", channel_type: "D"))
    assert_equal "p1", next_message.thread_id

    at = (Time.now.to_f * 1000).to_i + 60_000
    later = { "id" => "p2", "channel_id" => "ch-1", "user_id" => "u-adam", "root_id" => "",
              "message" => "@ops while you were out", "type" => "", "create_at" => at }
    seen = later.merge("id" => "p1", "message" => "@ops first", "create_at" => at - 1)
    @server.channel_posts = { "ch-1" => [seen, later] }
    @server.drop!
    @server.socket

    msg = next_message
    assert_equal "p2", msg.thread_id
    assert_equal "adam", msg.sender_name
    assert_nothing_delivered
    assert_equal at, @channel.cursor
  end

  # Break this catches: one failing handler killing the listener.
  def test_handler_errors_do_not_stop_the_stream
    ch = channel
    calls = 0
    ch.on_message do |msg|
      calls += 1
      raise "boom" if calls == 1

      @inbox << msg
    end
    ch.start!
    @server.socket
    @server.push(Posted.(id: "p1", message: "one", channel_type: "D"))
    @server.push(Posted.(id: "p2", message: "two", channel_type: "D"))
    assert_equal "p2", next_message.thread_id
    assert_match(/boom/, @log.string)
  end

  # Break this catches: a slow agent run stalling the socket (no pongs).
  def test_slow_handler_does_not_block_the_socket
    gate = Queue.new
    ch = channel
    ch.on_message { |msg| gate.pop; @inbox << msg }
    ch.start!
    @server.socket
    @server.push(Posted.(id: "p1", message: "slow", channel_type: "D"))
    @server.push_raw(0x9, "are-you-there")

    frame = Timeout.timeout(2) { @server.client_frames.pop }
    assert_equal [0xA, "are-you-there"], frame
    gate << :go
    assert_equal "p1", next_message.thread_id
  end

  private

  def drain
    out = []
    out << @inbox.pop until @inbox.empty?
    out
  end
end
