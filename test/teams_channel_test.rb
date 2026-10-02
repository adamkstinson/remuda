# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "stringio"
require "timeout"
require "tmpdir"
require "remuda"
require_relative "support/fake_bot_connector"

class TeamsChannelTest < Minitest::Test
  APP_ID = "app-123"
  BOT_ID = "28:app-123"
  SERVICE_URL = "https://smba.trafficmanager.net/amer/"

  def setup
    @keys = FakeBotFrameworkKeys.new
    @auth = Remuda::Channels::BotFrameworkAuth.new(app_id: APP_ID, openid_url: FakeBotFrameworkKeys::OPENID,
                                                   fetch: @keys.fetch)
    @log = StringIO.new
  end

  # --- JWT validation --------------------------------------------------------

  def test_a_token_signed_by_a_published_key_for_this_bot_is_accepted
    claims = @auth.verify!("Bearer #{valid_token}", service_url: SERVICE_URL, channel_id: "msteams")
    assert_equal APP_ID, claims["aud"]
  end

  def test_forged_and_unsigned_tokens_are_rejected
    forged = @keys.token(@keys.claims(app_id: APP_ID, service_url: SERVICE_URL), key: OpenSSL::PKey::RSA.generate(2048))
    unsigned = @keys.token(@keys.claims(app_id: APP_ID, service_url: SERVICE_URL), alg: "none")
    [nil, "", "Bearer", "Bearer abc.def", "Bearer #{forged}", "Bearer #{unsigned}"].each do |header|
      assert_raises(Remuda::Channels::BotFrameworkAuth::Invalid, header.to_s) do
        @auth.verify!(header, service_url: SERVICE_URL, channel_id: "msteams")
      end
    end
  end

  def test_claims_must_match_issuer_audience_time_and_service_url
    good = @keys.claims(app_id: APP_ID, service_url: SERVICE_URL)
    {
      "issuer" => good.merge("iss" => "https://evil.example"),
      "audience" => good.merge("aud" => "someone-else"),
      "expired" => good.merge("exp" => Time.now.to_i - 3600),
      "not yet valid" => good.merge("nbf" => Time.now.to_i + 3600),
      "service url" => good.merge("serviceurl" => "https://evil.example/")
    }.each do |what, claims|
      assert_raises(Remuda::Channels::BotFrameworkAuth::Invalid, what) do
        @auth.verify!("Bearer #{@keys.token(claims)}", service_url: SERVICE_URL, channel_id: "msteams")
      end
    end
  end

  def test_the_signing_key_must_be_endorsed_for_the_channel
    assert_raises(Remuda::Channels::BotFrameworkAuth::Invalid) do
      @auth.verify!("Bearer #{valid_token}", service_url: SERVICE_URL, channel_id: "skype")
    end
  end

  def test_signing_keys_are_cached
    3.times { @auth.verify!("Bearer #{valid_token}", service_url: SERVICE_URL, channel_id: "msteams") }
    assert_equal 2, @keys.fetches, "metadata + JWKS once"
  end

  # --- inbound ------------------------------------------------------------------

  def test_a_dm_reaches_on_message_and_the_post_returns_before_the_handler_finishes
    teams = build_teams
    received = Queue.new
    release = Queue.new
    teams.on_message { |msg| received << msg; release.pop }

    status, = Timeout.timeout(5) { teams.call(rack(activity(text: "hello there"))) }
    assert_equal 200, status

    msg = Timeout.timeout(5) { received.pop }
    assert_equal "teams:a:dm-conversation", msg.jid
    assert_equal "teams", msg.channel
    assert_equal "Adam", msg.sender_name
    assert_equal "hello there", msg.text
    assert_equal "act-1", msg.thread_id
  ensure
    release << true
    teams&.stop!
  end

  def test_a_channel_message_needs_a_mention_and_loses_it
    teams = build_teams
    received = Queue.new
    teams.on_message { |msg| received << msg }

    conversation = { "id" => "19:chan@thread.tacv2;messageid=1700", "conversationType" => "channel", "tenantId" => "t-1" }
    teams.call(rack(activity(id: "act-a", text: "no mention here", conversation: conversation)))
    teams.call(rack(activity(id: "act-b", text: "<at>Ops</at> what is due?", conversation: conversation,
                             entities: [{ "type" => "mention", "text" => "<at>Ops</at>",
                                          "mentioned" => { "id" => BOT_ID, "name" => "Ops" } }])))

    msg = Timeout.timeout(5) { received.pop }
    assert_equal "what is due?", msg.text
    assert_equal "teams:19:chan@thread.tacv2", msg.jid
    assert_equal "1700", msg.thread_id
    sleep 0.1
    assert received.empty?, "the unmentioned channel post must not reach the agent"
  ensure
    teams&.stop!
  end

  def test_forged_posts_are_rejected_and_never_handled
    teams = build_teams
    called = false
    teams.on_message { called = true }
    forged = @keys.token(@keys.claims(app_id: APP_ID, service_url: SERVICE_URL), key: OpenSSL::PKey::RSA.generate(2048))

    assert_equal 401, teams.call(rack(activity, token: forged)).first
    assert_equal 401, teams.call(rack(activity, token: nil)).first
    assert_equal 401, teams.call(rack(activity(service_url: "https://evil.example/"))).first
    sleep 0.1
    refute called
    assert_nil teams.references.get("teams:a:dm-conversation"), "a rejected post must not store a reference"
  ensure
    teams&.stop!
  end

  def test_replayed_activity_ids_are_dropped
    teams = build_teams
    received = Queue.new
    teams.on_message { |msg| received << msg }

    2.times { assert_equal 200, teams.call(rack(activity(id: "same"))).first }
    Timeout.timeout(5) { received.pop }
    sleep 0.1
    assert received.empty?
  ensure
    teams&.stop!
  end

  def test_allow_limits_senders_by_entra_object_id
    teams = build_teams(allow: ["aad-someone-else"])
    called = false
    teams.on_message { called = true }
    teams.call(rack(activity))
    sleep 0.1
    refute called
  ensure
    teams&.stop!
  end

  def test_non_post_and_bad_json_are_refused
    teams = build_teams
    assert_equal 405, teams.call("REQUEST_METHOD" => "GET", "rack.input" => StringIO.new("")).first
    env = rack(activity).merge("rack.input" => StringIO.new("{nope"))
    assert_equal 400, teams.call(env).first
  end

  # --- outbound -----------------------------------------------------------------

  def test_reply_goes_to_the_thread_with_a_cached_client_credentials_token
    connector = FakeBotConnector.new
    teams = build_teams(login_url: connector.url)
    teams.call(rack(activity(service_url: "#{connector.url}/")))

    assert_equal "act-1", teams.send_message(jid: "teams:a:dm-conversation", text: "**done**", thread_id: "act-1")
    teams.send_message(jid: "teams:a:dm-conversation", text: "again", thread_id: "act-1")

    first = connector.requests.pop
    assert_equal "POST", first[:method]
    assert_equal "/v3/conversations/a%3Adm-conversation/activities/act-1", first[:path]
    assert_equal "Bearer token-#{APP_ID}-1", first[:authorization]
    assert_equal "**done**", first[:body]["text"]
    assert_equal "markdown", first[:body]["textFormat"]
    assert_equal "act-1", first[:body]["replyToId"]
    assert_equal BOT_ID, first[:body].dig("from", "id")
    assert_equal 1, connector.token_requests, "token is cached between sends"
  ensure
    teams&.stop!
    connector&.close
  end

  def test_a_channel_thread_reply_targets_the_thread_conversation
    connector = FakeBotConnector.new
    teams = build_teams(login_url: connector.url)
    conversation = { "id" => "19:chan@thread.tacv2;messageid=1700", "conversationType" => "channel" }
    teams.call(rack(activity(service_url: connector.url, conversation: conversation,
                             entities: [{ "type" => "mention", "text" => "<at>Ops</at>",
                                          "mentioned" => { "id" => BOT_ID } }])))

    teams.send_message(jid: "teams:19:chan@thread.tacv2", text: "on it", thread_id: "1700")
    sent = connector.requests.pop
    assert_equal "/v3/conversations/19%3Achan%40thread.tacv2%3Bmessageid%3D1700/activities/1700", sent[:path]
  ensure
    teams&.stop!
    connector&.close
  end

  def test_a_workflow_can_message_a_stored_conversation_after_a_restart
    connector = FakeBotConnector.new
    Dir.mktmpdir("remuda-teams") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".remuda"))
      first = build_teams(login_url: connector.url, references: Remuda::Channels::Teams::DbReferences.new(dir))
      first.call(rack(activity(service_url: connector.url)))
      first.stop!
      ActiveRecord::Base.remove_connection

      restarted = build_teams(login_url: connector.url, references: Remuda::Channels::Teams::DbReferences.new(dir))
      assert_equal "sent-1", restarted.send_message(jid: "teams:a:dm-conversation", text: "shipment ready for review")
      sent = connector.requests.pop
      assert_equal "/v3/conversations/a%3Adm-conversation/activities", sent[:path]
      assert_nil restarted.send_message(jid: "teams:never-heard-from", text: "x")
    ensure
      ActiveRecord::Base.remove_connection if ActiveRecord::Base.connected?
    end
  ensure
    connector&.close
  end

  def test_channels_yml_binds_teams_with_secrets_from_env_and_durable_references
    Dir.mktmpdir("remuda-teams") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".remuda"))
      File.write(File.join(dir, ".remuda/channels.yml"), "transports:\n  teams:\n    mentions_only: false\n")
      File.write(File.join(dir, ".env"), "TEAMS_APP_ID=a\nTEAMS_APP_SECRET=s\nTEAMS_TENANT_ID=t\n")
      teams = Remuda.channels(dir).get("teams")
      assert_instance_of Remuda::Channels::Teams, teams
      assert_instance_of Remuda::Channels::Teams::DbReferences, teams.references
      assert teams.owns_jid?("teams:19:x")

      File.write(File.join(dir, ".env"), "TEAMS_APP_ID=a\n")
      error = assert_raises(ArgumentError) { Remuda.channels(dir) }
      assert_match(/TEAMS_APP_SECRET/, error.message)
    end
  end

  private

  def build_teams(**options)
    Remuda::Channels::Teams.new(app_id: APP_ID, app_secret: "secret", tenant_id: "tenant-1",
                                auth: @auth, logger: @log, **options)
  end

  def valid_token(service_url: SERVICE_URL)
    @keys.token(@keys.claims(app_id: APP_ID, service_url: service_url))
  end

  def activity(id: "act-1", text: "hi", service_url: SERVICE_URL, entities: nil,
               conversation: { "id" => "a:dm-conversation", "conversationType" => "personal", "tenantId" => "t-1" })
    {
      "type" => "message", "id" => id, "channelId" => "msteams", "serviceUrl" => service_url,
      "from" => { "id" => "29:adam", "name" => "Adam", "aadObjectId" => "aad-adam" },
      "recipient" => { "id" => BOT_ID, "name" => "Ops" },
      "conversation" => conversation, "text" => text, "entities" => entities
    }.compact
  end

  def rack(body, token: :valid)
    token = valid_token(service_url: body["serviceUrl"]) if token == :valid
    # A token for the real service URL, so a mismatched activity is caught.
    token = valid_token if body["serviceUrl"].include?("evil")
    env = { "REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(JSON.generate(body)) }
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    env
  end
end
