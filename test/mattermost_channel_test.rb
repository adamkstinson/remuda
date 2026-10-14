# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "timeout"
require "tmpdir"
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
    ch.handle_event(Posted.(id: "p4", message: "email ops@example.com or @opsy"))

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

  # Break this catches: a photo-only DM dropped because message is empty,
  # so the agent never sees the image.
  def test_photo_only_direct_message_arrives_with_the_file
    @server.add_file(id: "f1", name: "cat.jpg", data: "JPEGDATA")
    ch = channel
    ch.handle_event(Posted.(
      id: "p1", message: "", channel_type: "D", channel_id: "dm-1",
      file_ids: ["f1"],
      files: [{ "id" => "f1", "name" => "cat.jpg", "mime_type" => "image/jpeg", "size" => 8 }]
    ))

    msg = drain.first
    refute_nil msg, "expected a photo-only DM to be delivered"
    assert_equal "", msg.text
    assert_equal "cat.jpg", msg.files.first.name
    assert_equal "image/jpeg", msg.files.first.mime_type
    assert_equal "JPEGDATA", File.binread(msg.files.first.path)
  end

  def test_allow_list_limits_senders
    ch = channel(allow: ["@adam"])
    ch.handle_event(Posted.(id: "p1", message: "hi", channel_type: "D", sender: "@mallory"))
    ch.handle_event(Posted.(id: "p2", message: "hi", channel_type: "D", sender: "@adam"))
    assert_equal ["p2"], drain.map(&:thread_id)
  end

  # Break this catches: the bot answering every reply in a thread it joined.
  def test_thread_replies_need_a_tag_and_keep_the_root
    ch = channel
    ch.handle_event(Posted.(id: "r1", message: "and then?", root_id: "root", followers: ["bot-id"]))
    ch.handle_event(Posted.(id: "r2", message: "@ops and then?", root_id: "root", followers: ["bot-id"]))
    ch.handle_event(Posted.(id: "r3", message: "go", root_id: "root", mentions: ["bot-id"]))
    assert_equal [["@ops and then?", "root"], ["go", "root"]], drain.map { |m| [m.text, m.thread_id] }
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

  # Break this catches: the agent cannot find out where it is allowed to post,
  # so a workflow has to hard-code channel ids.
  def test_list_channels_is_every_membership_with_a_sendable_jid
    @server.channels = [
      { "id" => "ch-1", "name" => "ops", "type" => "O" },
      { "id" => "ch-2", "name" => "native-stack", "type" => "P" },
      { "id" => "ch-3", "name" => "bot-id__user-7", "type" => "D" }
    ]
    listed = channel.list_channels
    assert_equal [
      { "jid" => "mattermost:ch-1", "name" => "outfit/ops", "transport" => "mattermost", "kind" => "channel" },
      { "jid" => "mattermost:ch-2", "name" => "outfit/native-stack", "transport" => "mattermost", "kind" => "private" },
      { "jid" => "mattermost:ch-3", "name" => "@adam", "transport" => "mattermost", "kind" => "dm" }
    ], listed
    listed.each { |c| assert @channel.owns_jid?(c["jid"]) }
  end

  # Break this catches: a reply that is only text when the agent has a photo
  # to send, so the person never gets the image.
  def test_send_message_attaches_local_files
    dir = Dir.mktmpdir
    path = File.join(dir, "cat.jpg")
    File.binwrite(path, "JPEGDATA")
    ch = channel
    assert_equal "root-1", ch.send_message(
      jid: "mattermost:ch-9", text: "here", thread_id: "root-1", files: [path]
    )
    post = Timeout.timeout(2) { @server.posts.pop }
    assert_equal "here", post["message"]
    assert_equal "root-1", post["root_id"]
    assert_equal ["up-1"], post["file_ids"]
    upload = Timeout.timeout(2) { @server.uploads.pop }
    assert_equal "cat.jpg", upload["name"]
    assert_equal "JPEGDATA", upload["data"]
  ensure
    FileUtils.remove_entry(dir) if dir
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

  # Break this catches: a minutes-long agent run with no typing bubble, so
  # the person thinks the bot never saw the message.
  def test_handler_shows_typing_until_it_returns
    gate = Queue.new
    ch = channel(typing_interval: 0.05)
    ch.on_message { |msg| gate.pop; @inbox << msg }
    ch.start!
    @server.socket
    @server.push(Posted.(id: "p1", message: "status?", channel_id: "dm-1", channel_type: "D"))

    sleep 0.16
    seen = []
    seen << @server.typing.pop until @server.typing.empty?
    refute_empty seen, "expected typing while the handler ran"
    assert seen.size >= 4, "expected typing to pulse while the handler ran, got #{seen.inspect}"
    assert seen.any? { |event| event["channel_id"] == "dm-1" && !event.key?("parent_id") },
           "expected channel typing, got #{seen.inspect}"
    assert seen.any? { |event| event["parent_id"] == "p1" },
           "expected thread typing for the root, got #{seen.inspect}"

    gate << :go
    assert_equal "p1", next_message.thread_id
    sleep 0.16
    @server.typing.pop until @server.typing.empty?
    sleep 0.16
    assert @server.typing.empty?, "typing continued after the handler returned"
  ensure
    gate << :go if gate
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

  # Break this catches: an agent entering a thread for the first time only
  # seeing the triggering post, with no way to read what came before.
  def test_read_thread_returns_the_root_and_a_newest_window_oldest_first
    @server.add_thread("root", [thread_post("root", "topic", at: 1_000),
                                 thread_post("r1", "one", at: 1_001),
                                 thread_post("r2", "two", at: 1_002),
                                 thread_post("r3", "three", at: 1_003)])
    result = channel.read_thread(jid: "mattermost:ch-9", thread_id: "root")

    assert_equal "root", result["root"]["id"]
    assert_equal "topic", result["root"]["text"]
    assert_equal %w[r1 r2 r3], result["posts"].map { |post| post["id"] }
    assert_equal 0, result["omitted"]
    assert_nil result["before"]
    post = result["posts"].first
    assert_equal "adam", post["sender_name"]
    assert_equal "1970-01-01T00:00:01Z", post["created_at"]
  end

  def test_read_thread_windows_and_pages_a_long_thread
    replies = (1..199).map { |i| thread_post("r#{i}", "p#{i}", at: 1_000 + i) }
    @server.add_thread("root", [thread_post("root", "topic", at: 999)] + replies)

    ch = channel
    first = ch.read_thread(jid: "mattermost:ch-9", thread_id: "root")
    assert_equal 20, first["posts"].size
    assert_equal 179, first["omitted"]
    assert_equal "r180", first["before"]
    assert_equal (180..199).map { |i| "r#{i}" }, first["posts"].map { |post| post["id"] }

    seen = first["posts"].map { |post| post["id"] }
    before = first["before"]
    until before.nil?
      page = ch.read_thread(jid: "mattermost:ch-9", thread_id: "root", before: before)
      seen.concat(page["posts"].map { |post| post["id"] })
      before = page["before"]
    end
    assert_equal 199, seen.size
    assert_equal replies.map { |post| post["id"] }.sort, seen.sort
    assert_equal seen.size, seen.uniq.size
  end

  def test_read_thread_pages_a_paginated_server
    replies = (1..199).map { |i| thread_post("r#{i}", "p#{i}", at: 1_000 + i) }
    @server.add_thread("root", [thread_post("root", "topic", at: 999)] + replies)
    @server.paginate_threads = true
    ch = channel

    seen = []
    before = nil
    100.times do
      page = ch.read_thread(jid: "mattermost:ch-9", thread_id: "root", before: before)
      seen.concat(page["posts"].map { |post| post["id"] })
      before = page["before"]
      break if before.nil?
    end
    assert_nil before, "paging must terminate"
    assert_equal replies.map { |post| post["id"] }.sort, seen.sort
    assert_equal seen.size, seen.uniq.size
  end

  def test_read_thread_clamps_limit
    @server.add_thread("root", [thread_post("root", "topic", at: 999)] +
                               (1..60).map { |i| thread_post("r#{i}", "p#{i}", at: 1_000 + i) })
    ch = channel

    assert_equal 50, ch.read_thread(jid: "mattermost:ch-9", thread_id: "root", limit: 500)["posts"].size
    assert_equal 5, ch.read_thread(jid: "mattermost:ch-9", thread_id: "root", limit: 5)["posts"].size
  end

  def test_read_thread_marks_bot_posts_and_lists_file_names_without_downloading
    @server.add_thread("root", [
      thread_post("root", "topic", at: 1_000),
      thread_post("r1", "i am the bot", at: 1_001, user_id: "bot-id"),
      thread_post("r2", "another bot", at: 1_002, props: { "from_bot" => "true" }),
      thread_post("r3", "a person", at: 1_003,
                  files: [{ "id" => "f1", "name" => "cat.jpg", "mime_type" => "image/jpeg", "size" => 8 }])
    ])
    result = channel.read_thread(jid: "mattermost:ch-9", thread_id: "root")
    posts = result["posts"].to_h { |post| [post["id"], post] }

    assert posts["r1"]["from_bot"]
    assert posts["r2"]["from_bot"]
    refute posts["r3"]["from_bot"]
    assert_equal ["cat.jpg"], posts["r3"]["files"]
    refute @server.requests.any? { |_, path| path.include?("/files/f1") }, "the file must not be downloaded"
  end

  def test_read_thread_truncates_a_long_post
    @server.add_thread("root", [thread_post("root", "topic", at: 1_000),
                                thread_post("r1", "x" * 10_000, at: 1_001)])
    post = channel.read_thread(jid: "mattermost:ch-9", thread_id: "root")["posts"].first

    assert_equal 4_000 + "\u2026 (truncated)".length, post["text"].length
    assert post["text"].end_with?("\u2026 (truncated)")
  end

  def test_read_thread_drops_the_oldest_posts_when_the_tree_would_exceed_16k
    posts = [thread_post("root", "topic", at: 999)]
    posts += (1..40).map { |i| thread_post("r#{i}", "x" * 1_000, at: 1_000 + i) }
    @server.add_thread("root", posts)
    result = channel.read_thread(jid: "mattermost:ch-9", thread_id: "root")

    total = result["root"]["text"].length + result["posts"].sum { |post| post["text"].length }
    assert_operator total, :<=, 16_000
    assert_operator result["omitted"], :>=, 25
    assert result["posts"].size < 20
  end

  def test_read_thread_skips_system_and_deleted_posts
    @server.add_thread("root", [
      thread_post("root", "topic", at: 1_000),
      thread_post("r1", "joined", at: 1_001, type: "system_join_channel"),
      thread_post("r2", "gone", at: 1_002).merge("delete_at" => 5),
      thread_post("r3", "real", at: 1_003)
    ])
    assert_equal ["r3"], channel.read_thread(jid: "mattermost:ch-9", thread_id: "root")["posts"].map { |post| post["id"] }
  end

  def test_read_thread_failure_is_nil_not_a_crash
    @server.token = "other"
    assert_nil channel.read_thread(jid: "mattermost:ch-9", thread_id: "root")
    assert_match(/read_thread root/, @log.string)
  end

  def test_read_thread_for_an_unknown_jid_is_nil
    assert_nil channel.read_thread(jid: "telegram:42", thread_id: "root")
  end

  private

  def thread_post(id, message, at:, **opts)
    FakeMattermost.post_hash(id: id, message: message, create_at: at, **opts)
  end

  def drain
    out = []
    out << @inbox.pop until @inbox.empty?
    out
  end
end
