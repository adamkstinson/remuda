# frozen_string_literal: true

module Remuda
  class WorkflowStep < ActiveRecord::Base
    include ShownInPacific
    self.table_name = "workflow_steps"
    serialize :input, coder: JsonCoder
    serialize :output, coder: JsonCoder
    serialize :usage, coder: JsonCoder
  end
end
