# frozen_string_literal: true

module Remuda
  module Image
    NAME = "remuda-pi"

    def self.tag
      "#{NAME}:#{VERSION}"
    end
  end
end
