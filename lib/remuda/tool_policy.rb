# frozen_string_literal: true

module Remuda
  # Per-call control over what Pi may call, and what arguments some tools may
  # be called with:
  #
  #   Remuda.agent(prompt)                                   # everything
  #   Remuda.agent(prompt, tools: %w[read grep])             # allowlist
  #   Remuda.agent(prompt, exclude_tools: %w[bash write])    # denylist
  #   Remuda.agent(prompt, tools: {
  #     "read" => true,
  #     "channels_send_message" => { jid: msg.jid, thread_id: msg.thread_id }
  #   })
  #
  # The allowlist and denylist are passed to Pi as --tools / --exclude-tools.
  # Pinned arguments cannot be enforced by Pi: they are filled in by the host
  # where the tool is answered (ChannelsMcp), removed from the advertised
  # schema, and rejected if the model supplies a different value.
  class ToolPolicy
    # Pi tool names: built-ins (read, bash) and <server>_<tool> for MCP
    # (channels_send_message, planet_list_work_items).
    NAME = /\A[\w-]+\z/

    # tools: nil → no allowlist. Array → pure allowlist. Hash → allowlist with
    # pins; true (or anything that is not a Hash) means "allowed, no pins".
    def initialize(tools: nil, exclude_tools: nil)
      if !tools.nil? && !exclude_tools.nil?
        raise ArgumentError, "tools: and exclude_tools: are mutually exclusive"
      end

      @tools = tools
      @exclude_tools = exclude_tools
      @allow, @pins = parse_tools(tools)
      @deny = exclude_tools.nil? ? nil : Array(exclude_tools).map(&:to_s)
      validate_names!
    end

    # Keys are Pi tool names, values are { "argument" => value } with string
    # keys. Only tools the host answers can be pinned.
    attr_reader :allow, :deny, :pins

    def pi_args
      if !@tools.nil?
        allow.empty? ? ["--no-tools"] : ["--tools", allow.join(",")]
      elsif !@deny.nil? && !@deny.empty?
        ["--exclude-tools", deny.join(",")]
      else
        []
      end
    end

    # local_servers: the host-answered MCP servers in this call ("channels").
    # A pin anywhere else would silently do nothing, which is worse than loud.
    def validate!(local_servers: [])
      validate_names!

      pins.each_key do |name|
        next if local_servers.any? { |server| name.start_with?("#{server}_") }

        raise ArgumentError,
              "#{name}: pinned arguments are only for tools this host answers " \
              "(#{Array(local_servers).join(", ")}), not forwarded MCP servers"
      end

      self
    end

    private

    def validate_names!
      bad = [*allow, *deny].compact.find { |name| !name.match?(NAME) }
      raise ArgumentError, "invalid tool name: #{bad.inspect}" if bad
    end

    def parse_tools(tools)
      case tools
      when nil then [nil, {}]
      when Hash
        allow = tools.keys.map(&:to_s)
        pins = tools.each_with_object({}) do |(name, value), out|
          next unless value.is_a?(Hash) && !value.empty?

          out[name.to_s] = value.to_h { |key, val| [key.to_s, val] }
        end
        [allow, pins]
      else
        [Array(tools).map(&:to_s), {}]
      end
    end
  end
end
