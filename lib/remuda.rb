# frozen_string_literal: true

require "active_support/core_ext/time"

module Remuda
  # Stored times stay UTC so the scheduler can compare them to Time.now.utc.
  # Anything a person reads is Pacific.
  module Clock
    ZONE = "America/Los_Angeles"

    def self.format(time, zone = ZONE)
      return if time.nil?

      zone = ZONE if zone.nil? || zone.to_s.empty?
      time.in_time_zone(zone).strftime("%Y-%m-%d %H:%M:%S %Z")
    end
  end

  module ShownInPacific
    def format_for_inspect(name, value)
      return super unless time_value?(value)

      zone = respond_to?(:timezone) && !timezone.to_s.empty? ? timezone : Clock::ZONE
      %("#{Clock.format(value, zone)}")
    end

    private

    def time_value?(value)
      return true if value.is_a?(Time)
      return true if value.class.name == "ActiveSupport::TimeWithZone"
      return true if defined?(DateTime) && value.is_a?(DateTime)

      false
    end
  end
end

require_relative "remuda/version"
require_relative "remuda/image"
require_relative "remuda/db"
require_relative "remuda/current"
require_relative "remuda/json_coder"
require_relative "remuda/models/workflow_run"
require_relative "remuda/models/schedule"
require_relative "remuda/models/workflow_step"
require_relative "remuda/mcp"
require_relative "remuda/tool"
require_relative "remuda/sandbox"
require_relative "remuda/agent"
require_relative "remuda/runner"
require_relative "remuda/scheduler"
require_relative "remuda/directory"
require_relative "remuda/pi_auth"
require_relative "remuda/generator"
require_relative "remuda/cli"

module Remuda
end
