# frozen_string_literal: true

module Remuda
  class WorkflowRun < ActiveRecord::Base
    self.table_name = "workflow_runs"
    serialize :inputs, coder: JsonCoder
  end
end
