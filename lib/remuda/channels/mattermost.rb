# frozen_string_literal: true

require "json"
require "net/http"
require "set"
require "uri"

module Remuda
  module Channels
    # Mattermost transport. Authenticates as one bot (a personal access token),
    # receives over the websocket event stream, replies over REST.
    #
    # Addressing: jid is "mattermost:<channel_id>"; thread_id is the root post
    # id. Replying with thread_id keeps the answer in the thread.
    #
    # What counts as inbound (mentions_only: true, the default): a direct
    # message, or a post that @mentions the bot. A reply in a thread the bot
    # is part of still has to tag it. The bot's own posts, system posts, and
    # posts from other bots (ignore_bots) never count. allow: limits senders to
    # a list of usernames.
    #
    # Reconnects with backoff. After a reconnect it backfills posts created
    # since the last one seen, so a dropped socket does not drop a message.
    # The cursor lives in memory; pass since: to resume across restarts.
    class Mattermost < Channel
      NAME = "mattermost"
      PREFIX = "mattermost:"
      SEEN_LIMIT = 1000

      class Error < StandardError; end

      def self.from_config(config, env = {})
        token_env = config.fetch("token_env", "MATTERMOST_TOKEN")
        token = env[token_env] || ENV[token_env]
        raise ArgumentError, "mattermost: #{token_env} is not set in the agent's .env" if token.to_s.empty?

        url = config["url"] || env["MATTERMOST_URL"] || ENV["MATTERMOST_URL"]
        raise ArgumentError, "mattermost: url is required in .remuda/channels.yml" if url.to_s.empty?

        new(
          url: url,
          token: token,
          mentions_only: config.fetch("mentions_only", true),
          ignore_bots: config.fetch("ignore_bots", true),
          allow: config["allow"]
        )
      end

      attr_reader :cursor

      def initialize(url:, token:, mentions_only: true, ignore_bots: true,
                     allow: nil, since: nil, reconnect_delay: 5, max_reconnect_delay: 60,
                     ping_interval: 30, logger: $stderr)
        super()
        @base = url.to_s.chomp("/")
        @token = token
        @mentions_only = mentions_only
        @ignore_bots = ignore_bots
        @allow = allow && Array(allow).map { |name| name.to_s.delete_prefix("@") }
        @cursor = since
        @reconnect_delay = reconnect_delay
        @max_reconnect_delay = max_reconnect_delay
        @ping_interval = ping_interval
        @logger = logger
        @seen = []
        @seen_set = Set.new
        @usernames = {}
        @lock = Mutex.new
        @running = false
      end

      def name
        NAME
      end

      def owns_jid?(jid)
        jid.to_s.start_with?(PREFIX)
      end

      # The bot's own user record.
      def me
        @me ||= api(:get, "/users/me")
      end

      # Inbound is handed to on_message on one worker thread, in arrival order,
      # so a handler that runs an agent for minutes never stalls the socket.
      def start!
        return if @running

        me
        @running = true
        @queue = Queue.new
        @worker = Thread.new { work }
        @thread = Thread.new { run }
        nil
      end

      def stop!
        @running = false
        @socket&.close
        @thread&.join(5)
        @queue&.close
        @worker&.join(5)
        @thread = @worker = @queue = nil
        nil
      end

      def running?
        @running
      end

      def send_message(jid:, text:, thread_id: nil)
        channel_id = channel_id_for(jid)
        return nil unless channel_id

        body = { channel_id: channel_id, message: text.to_s }
        body[:root_id] = thread_id.to_s unless thread_id.to_s.empty?
        post = api(:post, "/posts", body)
        remember(post["id"])
        thread_id.to_s.empty? ? post["id"] : thread_id.to_s
      rescue Error, SystemCallError, IOError, Timeout::Error => e
        log("send_message to #{jid} failed: #{e.message}")
        nil
      end

      # jid of the direct-message channel between the bot and a user, for
      # outbound-only use ("tell them the run finished").
      def dm_jid(username)
        user = api(:get, "/users/username/#{URI.encode_www_form_component(username.to_s.delete_prefix("@"))}")
        channel = api(:post, "/channels/direct", [me["id"], user["id"]])
        "#{PREFIX}#{channel["id"]}"
      end

      # jid of a named channel on a team (team and channel are URL names).
      def channel_jid(team:, channel:)
        found = api(:get, "/teams/name/#{team}/channels/name/#{channel}")
        "#{PREFIX}#{found["id"]}"
      end

      # One websocket event, as parsed JSON. Public so a caller can feed events
      # it received some other way; the listener uses it too.
      def handle_event(event)
        return unless event.is_a?(Hash) && event["event"] == "posted"

        data = event["data"] || {}
        post = parse_json(data["post"])
        return unless post.is_a?(Hash)

        consider(
          post,
          channel_type: data["channel_type"],
          sender: data["sender_name"],
          mentions: Array(parse_json(data["mentions"]))
        )
      end

      private

      def deliver(message)
        @queue ? @queue << message : super
      rescue ClosedQueueError
        nil
      end

      def work
        while (message = @queue&.pop)
          begin
            @on_message&.call(message)
          rescue StandardError => e
            log("on_message failed for #{message.jid}: #{e.class}: #{e.message}")
          end
        end
      end

      def run
        delay = @reconnect_delay
        while @running
          begin
            connect
            backfill if @cursor
            @cursor ||= now_ms
            delay = @reconnect_delay
            listen
          rescue StandardError => e
            log("#{e.class}: #{e.message}") if @running
          ensure
            @socket&.close
            @socket = nil
          end
          break unless @running

          sleep(delay)
          delay = [delay * 2, @max_reconnect_delay].min
        end
      end

      def connect
        url = "#{@base.sub(/\Ahttp/, "ws")}/api/v4/websocket"
        @socket = WebSocket.new(url, headers: { "Authorization" => "Bearer #{@token}" }).connect
        deadline = monotonic + 10
        loop do
          text = @socket.read_message(timeout: [deadline - monotonic, 0.1].max)
          raise Error, "no hello from #{url}; is the token valid?" if text.nil? && monotonic >= deadline
          next unless text

          event = parse_json(text)
          break if event.is_a?(Hash) && event["event"] == "hello"
        end
      end

      def listen
        last_ping = monotonic
        while @running
          text = @socket.read_message(timeout: 1)
          handle_event(parse_json(text)) if text

          next unless monotonic - last_ping >= @ping_interval

          raise Error, "no traffic for #{@ping_interval * 2}s" if monotonic - @socket.last_activity > @ping_interval * 2

          @socket.ping
          last_ping = monotonic
        end
      end

      # Posts created at or after the cursor in every channel the bot belongs to.
      # No mention list here, so a mention is recognized in the text.
      def backfill
        since = @cursor
        channels = api(:get, "/users/me/teams").flat_map do |team|
          api(:get, "/users/me/teams/#{team["id"]}/channels")
        end
        posts = channels.uniq { |channel| channel["id"] }.flat_map do |channel|
          list = api(:get, "/channels/#{channel["id"]}/posts?since=#{since}")
          (list["order"] || []).map { |id| [list.dig("posts", id), channel["type"]] }
        end
        posts.compact.sort_by { |post, _| post["create_at"].to_i }.each do |post, type|
          next if post["create_at"].to_i < since || post["delete_at"].to_i.positive?

          consider(post, channel_type: type, sender: username_for(post["user_id"]), mentions: [])
        end
      end

      def consider(post, channel_type:, sender:, mentions:)
        id = post["id"]
        return if id.nil? || !remember(id)

        advance(post["create_at"])
        return unless post["type"].to_s.empty?
        return if post["user_id"] == me["id"]
        return if @ignore_bots && post.dig("props", "from_bot").to_s == "true"

        text = post["message"].to_s
        return if text.strip.empty?

        sender = sender.to_s.delete_prefix("@")
        return if @allow && !@allow.include?(sender)
        return unless addressed?(channel_type, mentions, text)

        root = post["root_id"].to_s.empty? ? id : post["root_id"]
        deliver(IncomingMessage.new(
          jid: "#{PREFIX}#{post["channel_id"]}",
          channel: NAME,
          text: text,
          sender_name: sender,
          thread_id: root,
          bot_token_key: me["username"]
        ))
      rescue StandardError => e
        log("dropped post #{post["id"]}: #{e.class}: #{e.message}")
      end

      # Being in a thread is not being addressed: replies must tag the bot too.
      def addressed?(channel_type, mentions, text)
        return true unless @mentions_only
        return true if channel_type == "D"
        return true if mentions.include?(me["id"])

        text.match?(/(?<![\w@])@#{Regexp.escape(me["username"].to_s)}(?![\w-])/i)
      end

      # true the first time a post id is seen.
      def remember(id)
        @lock.synchronize do
          return false if @seen_set.include?(id)

          @seen << id
          @seen_set << id
          @seen_set.delete(@seen.shift) while @seen.size > SEEN_LIMIT
          true
        end
      end

      def advance(create_at)
        at = create_at.to_i
        @cursor = at if at.positive? && (@cursor.nil? || at > @cursor)
      end

      def username_for(user_id)
        @usernames[user_id] ||= api(:get, "/users/#{user_id}")["username"].to_s
      rescue Error
        ""
      end

      def channel_id_for(jid)
        return nil unless owns_jid?(jid)

        id = jid.to_s.delete_prefix(PREFIX)
        id.empty? ? nil : id
      end

      def api(method, path, body = nil)
        uri = URI("#{@base}/api/v4#{path}")
        request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "application/json"
        if body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                                           open_timeout: 10, read_timeout: 30) do |http|
          http.request(request)
        end
        payload = response.body.to_s.empty? ? {} : JSON.parse(response.body)
        unless response.is_a?(Net::HTTPSuccess)
          detail = payload.is_a?(Hash) ? payload["message"] : nil
          raise Error, "#{method.upcase} #{path}: HTTP #{response.code} #{detail}".strip
        end
        payload
      rescue JSON::ParserError
        raise Error, "#{method.upcase} #{path}: response is not JSON"
      end

      def parse_json(value)
        return value unless value.is_a?(String)

        JSON.parse(value)
      rescue JSON::ParserError
        nil
      end

      def log(message)
        @logger&.puts("[remuda mattermost] #{message}")
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def now_ms
        (Time.now.to_f * 1000).to_i
      end
    end

    register_transport(Mattermost::NAME, Mattermost)
  end
end
