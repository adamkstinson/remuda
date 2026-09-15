# frozen_string_literal: true

module Remuda
  class Schedule < ActiveRecord::Base
    self.table_name = "schedules"
    serialize :inputs, coder: JsonCoder
  end
end
