# frozen_string_literal: true

require "json"

module Remuda
  module JsonCoder
    def self.dump(obj)
      obj.nil? ? nil : JSON.generate(obj)
    end

    def self.load(raw)
      return {} if raw.nil? || raw == ""
      return raw if raw.is_a?(Hash)

      JSON.parse(raw)
    end
  end
end
