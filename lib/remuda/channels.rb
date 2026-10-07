# frozen_string_literal: true

require "yaml"

module Remuda
  # Transports live in the gem; bindings live in the agent
  # (.remuda/channels.yml), tokens in the agent's .env.
  #
  # A channel responds to:
  #   name            -> String   transport identifier ("mattermost")
  #   owns_jid?(jid)  -> bool     does this channel manage this address?
  #   start!          -> nil      begin receiving; inbound goes to on_message
  #   stop!           -> nil      graceful shutdown
  #   send_message(jid:, text:, thread_id: nil, files: nil) -> String | nil
  #     Deliver text and optional local file paths. Returns the thread it
  #     landed in, nil if undeliverable. Without thread_id it starts a new
  #     thread and returns that thread's root.
  #   list_channels   -> [Hash]   every place this transport can send to:
  #     { "jid", "name", "transport", "kind" } with kind one of
  #     channel / private / dm / group. Default is none.
  module Channels
    # A file that arrived with an inbound message, already on disk.
    Attachment = Data.define(:id, :name, :mime_type, :size, :path)

    # A normalized inbound message; everything transport-specific is gone.
    IncomingMessage = Data.define(
      :jid,           # opaque per-channel address; pass back to send_message
      :channel,       # which transport produced it ("mattermost")
      :text,
      :sender_name,
      :thread_id,     # conversation unit: reply here to stay in-thread
      :bot_token_key, # which bot identity received it, or nil
      :files          # Attachment list; empty when the post has no files
    ) do
      def initialize(jid:, channel:, text:, sender_name:, thread_id:, bot_token_key: nil, files: [])
        super(jid:, channel:, text:, sender_name:, thread_id:, bot_token_key:, files: Array(files))
      end
    end

    class Channel
      def initialize
        @on_message = nil
      end

      def on_message(&block)
        @on_message = block
        self
      end

      def list_channels
        []
      end

      private

      def deliver(message)
        @on_message&.call(message)
      end
    end

    # The one place the rest of the system touches a channel. An agent with
    # no bindings gets an empty registry, and every call on it is a no-op.
    class Registry
      include Enumerable

      def initialize
        @channels = {}
      end

      def register(channel)
        @channels[channel.name] = channel
        channel
      end

      def get(name)
        @channels[name.to_s]
      end
      alias [] get

      def each(&block)
        @channels.each_value(&block)
      end

      def names
        @channels.keys
      end

      def empty?
        @channels.empty?
      end

      def for_jid(jid)
        @channels.each_value.find { |channel| channel.owns_jid?(jid) }
      end

      def send_message(jid:, text:, thread_id: nil, files: nil)
        for_jid(jid)&.send_message(jid: jid, text: text, thread_id: thread_id, files: files)
      end

      # One flat list across every bound transport.
      def list_channels
        flat_map(&:list_channels)
      end

      # Route every bound channel's inbound to one handler.
      def on_message(&block)
        each { |channel| channel.on_message(&block) }
        self
      end

      def start_all
        each(&:start!)
      end

      def stop_all
        each(&:stop!)
      end
    end

    TRANSPORTS = {}

    def self.register_transport(name, klass)
      TRANSPORTS[name.to_s] = klass
    end

    # Build the registry from an agent's .remuda/channels.yml:
    #
    #   transports:
    #     mattermost:
    #       url: https://chat.example.com
    #       token_env: MATTERMOST_TOKEN
    def self.load(agent_dir = nil)
      dir = File.expand_path(agent_dir || Current.agent_dir || Dir.pwd)
      path = File.join(dir, ".remuda/channels.yml")
      config = read_config(dir)
      env = Directory.env_vars(dir)

      registry = Registry.new
      (config["transports"] || {}).each do |name, spec|
        klass = TRANSPORTS.fetch(name.to_s) do
          raise ArgumentError,
                "unknown channel transport #{name.inspect} in #{path} (known: #{TRANSPORTS.keys.join(", ")})"
        end
        registry.register(build(klass, spec || {}, env, dir))
      end
      registry
    end

    # Does the agent bind any transport? Reads channels.yml only; it does not
    # build the channels, so it needs no token.
    def self.bound?(agent_dir = nil)
      transports = read_config(File.expand_path(agent_dir || Current.agent_dir || Dir.pwd))["transports"]
      transports.is_a?(Hash) && !transports.empty?
    end

    def self.read_config(dir)
      path = File.join(dir, ".remuda/channels.yml")
      config = File.file?(path) ? YAML.safe_load_file(path) : nil
      config.is_a?(Hash) ? config : {}
    end
    private_class_method :read_config

    # channels.send_message as a tool: the same call for a workflow script
    # (Remuda.tool) and for the sandboxed agent (ChannelsMcp).
    module SendTool
      NAME = "send_message"
      DESCRIPTION = "Send a message on one of this agent's channels (Mattermost, ...). " \
                    "Returns the thread it landed in."
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "jid" => { "type" => "string",
                     "description" => "Channel address, e.g. mattermost:<channel_id>. Use the jid a message came from to answer it." },
          "text" => { "type" => "string", "description" => "Message text (Markdown)." },
          "thread_id" => { "type" => "string", "description" => "Reply in this thread. Omit to start a new one." },
          "files" => { "type" => "array", "items" => { "type" => "string" },
                       "description" => "Paths of files to attach." }
        },
        "required" => %w[jid text]
      }.freeze

      def self.catalog_entry
        { server: "channels", name: NAME, description: DESCRIPTION, input_schema: SCHEMA }
      end

      def self.call(registry, args)
        args = args.transform_keys(&:to_s)
        jid = args["jid"].to_s
        raise ArgumentError, "send_message needs jid and text" if jid.empty? || args["text"].nil?

        thread = registry.send_message(
          jid: jid,
          text: args["text"].to_s,
          thread_id: args["thread_id"],
          files: args["files"]
        )
        raise "channels.send_message: not delivered to #{jid}" if thread.nil?

        { "thread_id" => thread }
      end
    end

    # channels.list_channels: everywhere the agent can send, across transports.
    module ListTool
      NAME = "list_channels"
      DESCRIPTION = "List every channel, DM, and group this agent can send to, across all its " \
                    "transports. Each entry has a jid for send_message."
      SCHEMA = { "type" => "object", "properties" => {} }.freeze

      def self.catalog_entry
        { server: "channels", name: NAME, description: DESCRIPTION, input_schema: SCHEMA }
      end

      def self.call(registry, _args = {})
        { "channels" => registry.list_channels }
      end
    end

    TOOLS = { SendTool::NAME => SendTool, ListTool::NAME => ListTool }.freeze
  end

  module Channels
    # Transports that keep state across restarts (Teams) take agent_dir:.
    def self.build(klass, spec, env, dir)
      takes_dir = klass.method(:from_config).parameters.any? { |kind, name| name == :agent_dir || kind == :keyrest }
      takes_dir ? klass.from_config(spec, env, agent_dir: dir) : klass.from_config(spec, env)
    end
    private_class_method :build
  end

  def self.channels(agent_dir = nil)
    Channels.load(agent_dir)
  end
end

require_relative "channels/websocket"
require_relative "channels/mattermost"
require_relative "channels/bot_framework_auth"
require_relative "channels/teams"
