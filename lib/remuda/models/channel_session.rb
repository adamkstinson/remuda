# frozen_string_literal: true

module Remuda
  # Per-conversation channel state a transport must keep across restarts
  # (Teams: the conversation reference needed to message someone first).
  class ChannelSession < ActiveRecord::Base
    include ShownInPacific
    self.table_name = "channel_sessions"
    serialize :data, coder: JsonCoder
  end
end
