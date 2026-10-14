# frozen_string_literal: true

module Remuda
  # Which Pi session (and therefore which growing conversation) a channel
  # thread resumes. One row per (jid, thread_id); session_id is the id passed
  # to Pi as --session-id.
  class ChannelThread < ActiveRecord::Base
    include ShownInPacific
    self.table_name = "channel_threads"
  end
end
