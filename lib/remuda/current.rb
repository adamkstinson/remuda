# frozen_string_literal: true

require "active_support/current_attributes"

module Remuda
  class Current < ActiveSupport::CurrentAttributes
    attribute :run
    attribute :agent_dir
    attribute :inputs
  end
end
