# frozen_string_literal: true

require "yaml"

module Remuda
  # Transports live in the gem; bindings live in the agent
  # (.remuda/channels.yml), tokens in the agent's .env. See design/06-channels.md.
  #
  # A channel responds to:
  #   name            -> String   transport identifier ("mattermost")
  #   owns_jid?(jid)  -> bool     does this channel manage this address?
  #   start!          -> nil      begin receiving; inbound goes to on_message
  #   stop!           -> nil      graceful shutdown
  #   send_message(jid:, text:, thread_id: nil) -> String | nil
  #     Deliver text. Returns the thread it landed in, nil if undeliverable.
  #     Without thread_id it starts a new thread and returns that thread's root.
  module Channels
    # A normalized inbound message; everything transport-specific is gone.
    IncomingMessage = Data.define(
      :jid,           # opaque per-channel address; pass back to send_message
      :channel,       # which transport produced it ("mattermost")
      :text,
      :sender_name,
      :thread_id,     # conversation unit: reply here to stay in-thread
      :bot_token_key  # which bot identity received it, or nil
    )

    class Channel
      def initialize
        @on_message = nil
      end

      def on_message(&block)
        @on_message = block
        self
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

      def send_message(jid:, text:, thread_id: nil)
        for_jid(jid)&.send_message(jid: jid, text: text, thread_id: thread_id)
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
    #       url: https://chat.darkhorse.so
    #       token_env: MATTERMOST_TOKEN
    def self.load(agent_dir = nil)
      dir = File.expand_path(agent_dir || Current.agent_dir || Dir.pwd)
      path = File.join(dir, ".remuda/channels.yml")
      config = File.file?(path) ? (YAML.safe_load_file(path) || {}) : {}
      env = Directory.env_vars(dir)

      registry = Registry.new
      (config["transports"] || {}).each do |name, spec|
        klass = TRANSPORTS.fetch(name.to_s) do
          raise ArgumentError,
                "unknown channel transport #{name.inspect} in #{path} (known: #{TRANSPORTS.keys.join(", ")})"
        end
        registry.register(klass.from_config(spec || {}, env))
      end
      registry
    end
  end

  def self.channels(agent_dir = nil)
    Channels.load(agent_dir)
  end
end

require_relative "channels/websocket"
require_relative "channels/mattermost"
