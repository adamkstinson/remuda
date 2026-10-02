# frozen_string_literal: true

require "json"
require "net/http"
require "set"
require "uri"

module Remuda
  module Channels
    # Microsoft Teams transport over the Bot Framework REST API, no SDK.
    #
    # Teams is inbound by webhook: the Bot Connector POSTs each activity to
    # the bot's messaging endpoint. This object is that endpoint as a Rack app
    # (call(env)); mount it in a host app or serve it with any Rack server,
    # behind TLS the operator provides. Every POST must carry a valid Bot
    # Framework JWT (BotFrameworkAuth) or it is a 401. The POST is answered
    # 200 at once; on_message runs on one worker thread, in order.
    #
    # Addressing: jid is "teams:<conversation id>" (without ;messageid=);
    # thread_id is the root message id of a channel thread, or the activity
    # id elsewhere. Replies go to the thread.
    #
    # Messaging someone first needs a conversation reference (service URL,
    # conversation id, tenant, bot id) from an earlier inbound activity. Those
    # are kept as channel_sessions rows in the agent's SQLite, so a restart
    # does not lose them.
    #
    # What counts as inbound (mentions_only: true, the default): a personal
    # chat, or a channel / group chat message that @mentions the bot; the
    # mention is stripped from the text. allow: limits senders to Entra
    # (AAD) object ids. Replayed activity ids are dropped. Text and Markdown
    # only: no cards or attachments in v1.
    class Teams < Channel
      NAME = "teams"
      PREFIX = "teams:"
      SCOPE = "https://api.botframework.com/.default"
      LOGIN_URL = "https://login.microsoftonline.com"
      SEEN_LIMIT = 1000

      class Error < StandardError; end

      # Conversation references in the agent's SQLite (channel_sessions).
      class DbReferences
        def initialize(agent_dir)
          @agent_dir = agent_dir
        end

        def get(jid)
          with_db { ChannelSession.find_by(channel: NAME, jid: jid)&.data }
        end

        def put(jid, reference)
          with_db do
            row = ChannelSession.find_or_initialize_by(channel: NAME, jid: jid)
            row.update!(data: reference)
          end
        end

        private

        def with_db(&block)
          Db.connect(@agent_dir) unless ActiveRecord::Base.connected?
          ActiveRecord::Base.connection_pool.with_connection(&block)
        end
      end

      # For tests, or a host that keeps references itself.
      class MemoryReferences
        def initialize
          @refs = {}
          @lock = Mutex.new
        end

        def get(jid) = @lock.synchronize { @refs[jid] }
        def put(jid, reference) = @lock.synchronize { @refs[jid] = reference }
      end

      def self.from_config(config, env = {}, agent_dir: nil)
        value = lambda do |key, default|
          name = config.fetch(key, default)
          found = env[name] || ENV[name]
          raise ArgumentError, "teams: #{name} is not set in the agent's .env" if found.to_s.empty?

          found
        end

        new(
          app_id: value.call("app_id_env", "TEAMS_APP_ID"),
          app_secret: value.call("app_secret_env", "TEAMS_APP_SECRET"),
          tenant_id: value.call("tenant_id_env", "TEAMS_TENANT_ID"),
          mentions_only: config.fetch("mentions_only", true),
          allow: config["allow"],
          references: agent_dir ? DbReferences.new(agent_dir) : MemoryReferences.new
        )
      end

      attr_reader :references

      def initialize(app_id:, app_secret:, tenant_id:, mentions_only: true, allow: nil,
                     references: MemoryReferences.new, auth: nil, login_url: LOGIN_URL, logger: $stderr)
        super()
        @app_id = app_id
        @app_secret = app_secret
        @tenant_id = tenant_id
        @mentions_only = mentions_only
        @allow = allow && Array(allow).map(&:to_s)
        @references = references
        @auth = auth || BotFrameworkAuth.new(app_id: app_id)
        @login_url = login_url.to_s.chomp("/")
        @logger = logger
        @seen = []
        @seen_set = Set.new
        @lock = Mutex.new
        @token_lock = Mutex.new
        @queue = nil
      end

      def name
        NAME
      end

      def owns_jid?(jid)
        jid.to_s.start_with?(PREFIX)
      end

      def start!
        @lock.synchronize do
          return if @queue

          @queue = Queue.new
          @worker = Thread.new { work }
        end
        nil
      end

      def stop!
        queue, worker = @lock.synchronize { [@queue, @worker] }
        queue&.close
        worker&.join(5)
        @lock.synchronize { @queue = @worker = nil }
        nil
      end

      def running?
        !@queue.nil?
      end

      # The messaging endpoint, as a Rack app.
      def call(env)
        return respond(405, "POST only\n", "allow" => "POST") unless env["REQUEST_METHOD"] == "POST"

        activity = JSON.parse(env["rack.input"].read.to_s)
        return respond(400, "not an activity\n") unless activity.is_a?(Hash)

        @auth.verify!(env["HTTP_AUTHORIZATION"],
                      service_url: activity["serviceUrl"], channel_id: activity["channelId"])
        receive(activity)
        respond(200, "{}", "content-type" => "application/json")
      rescue JSON::ParserError
        respond(400, "not JSON\n")
      rescue BotFrameworkAuth::Invalid => e
        log("rejected inbound activity: #{e.message}")
        respond(401, "unauthorized\n")
      end

      # One authenticated activity. Public so a caller that verified the
      # request some other way can feed it in; the Rack app uses it too.
      def receive(activity)
        id = activity["id"]
        return if id && !remember(id)

        keep_reference(activity)
        return unless activity["type"] == "message"

        message = incoming(activity)
        return if message.nil?

        start! unless running?
        @queue << message
      rescue ClosedQueueError
        nil
      end

      def send_message(jid:, text:, thread_id: nil, files: nil)
        reference = @references.get(jid)
        if reference.nil?
          log("send_message to #{jid}: no conversation reference yet (the bot must hear from it first)")
          return nil
        end
        log("send_message to #{jid}: file attachments are not supported, sending text only") unless Array(files).empty?

        conversation = reference["conversation_id"]
        thread = thread_id.to_s.empty? ? nil : thread_id.to_s
        conversation = "#{conversation};messageid=#{thread}" if thread && reference["conversation_type"] == "channel"
        path = "/v3/conversations/#{escape(conversation)}/activities"
        path += "/#{escape(thread)}" if thread

        activity = {
          "type" => "message",
          "text" => text.to_s,
          "textFormat" => "markdown",
          "from" => { "id" => reference["bot_id"], "name" => reference["bot_name"] }.compact,
          "conversation" => { "id" => conversation },
          "replyToId" => thread
        }.compact
        posted = connector(reference["service_url"], path, activity)
        thread || posted["id"]
      rescue Error, SystemCallError, IOError, Timeout::Error => e
        log("send_message to #{jid} failed: #{e.message}")
        nil
      end

      private

      def incoming(activity)
        from = activity["from"] || {}
        recipient = activity["recipient"] || {}
        return nil if from["id"] && from["id"] == recipient["id"]
        return nil if @allow && !@allow.include?(from["aadObjectId"].to_s)

        mentioned = bot_mentioned?(activity)
        return nil if @mentions_only && !personal?(activity) && !mentioned

        IncomingMessage.new(
          jid: jid_for(activity),
          channel: NAME,
          text: strip_mentions(activity),
          sender_name: from["name"],
          thread_id: thread_for(activity),
          files: []
        )
      end

      def keep_reference(activity)
        conversation = activity["conversation"] || {}
        return if conversation["id"].to_s.empty? || activity["serviceUrl"].to_s.empty?

        recipient = activity["recipient"] || {}
        @references.put(jid_for(activity), {
          "service_url" => activity["serviceUrl"],
          "conversation_id" => base_conversation(conversation["id"]),
          "conversation_type" => conversation["conversationType"],
          "tenant_id" => conversation["tenantId"] || activity.dig("channelData", "tenant", "id"),
          "bot_id" => recipient["id"],
          "bot_name" => recipient["name"]
        }.compact)
      rescue StandardError => e
        log("could not store the conversation reference: #{e.class}: #{e.message}")
      end

      def personal?(activity)
        type = activity.dig("conversation", "conversationType")
        type.nil? || type == "personal"
      end

      def bot_mentions(activity)
        bot = activity.dig("recipient", "id")
        Array(activity["entities"]).select do |entity|
          entity["type"] == "mention" && entity.dig("mentioned", "id") == bot
        end
      end

      def bot_mentioned?(activity)
        !bot_mentions(activity).empty?
      end

      def strip_mentions(activity)
        text = activity["text"].to_s
        bot_mentions(activity).each do |entity|
          text = text.gsub(entity["text"].to_s, "") unless entity["text"].to_s.empty?
        end
        text.gsub(/\s+/, " ").strip
      end

      def jid_for(activity)
        "#{PREFIX}#{base_conversation(activity.dig("conversation", "id"))}"
      end

      def base_conversation(id)
        id.to_s.split(";messageid=").first.to_s
      end

      def thread_for(activity)
        activity.dig("conversation", "id").to_s[/;messageid=([^;]+)/, 1] || activity["replyToId"] || activity["id"]
      end

      def work
        while (message = @queue&.pop)
          begin
            deliver(message)
          rescue StandardError => e
            log("on_message failed for #{message.jid}: #{e.class}: #{e.message}")
          end
        end
      end

      def connector(service_url, path, body)
        uri = URI("#{service_url.to_s.chomp("/")}#{path}")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{access_token}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
        response = http(uri) { |h| h.request(request) }
        raise Error, "POST #{uri.path}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end

      # Client credentials against the single-tenant Entra app, cached until
      # a minute before it expires.
      def access_token
        @token_lock.synchronize do
          return @token if @token && Time.now < @token_expires

          uri = URI("#{@login_url}/#{@tenant_id}/oauth2/v2.0/token")
          request = Net::HTTP::Post.new(uri)
          request.set_form_data(
            "grant_type" => "client_credentials",
            "client_id" => @app_id,
            "client_secret" => @app_secret,
            "scope" => SCOPE
          )
          response = http(uri) { |h| h.request(request) }
          raise Error, "token request: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          data = JSON.parse(response.body)
          @token = data.fetch("access_token")
          @token_expires = Time.now + data.fetch("expires_in", 3600).to_i - 60
          @token
        rescue JSON::ParserError, KeyError
          raise Error, "token request: unexpected response"
        end
      end

      def http(uri, &block)
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                                open_timeout: 10, read_timeout: 30, &block)
      end

      def escape(value)
        URI.encode_www_form_component(value.to_s).gsub("+", "%20")
      end

      def remember(id)
        @lock.synchronize do
          return false if @seen_set.include?(id)

          @seen << id
          @seen_set << id
          @seen_set.delete(@seen.shift) while @seen.size > SEEN_LIMIT
          true
        end
      end

      def respond(status, body, headers = {})
        [status, { "content-type" => "text/plain" }.merge(headers), [body]]
      end

      def log(message)
        @logger&.puts("[teams] #{message}")
      end
    end

    register_transport(Teams::NAME, Teams)
  end
end
