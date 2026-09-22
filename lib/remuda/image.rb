# frozen_string_literal: true

module Remuda
  module Image
    NAME = "remuda-pi"
    TAG = "latest"

    def self.tag
      "#{NAME}:#{TAG}"
    end
  end
end
