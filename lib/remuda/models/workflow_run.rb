# frozen_string_literal: true

module Remuda
  class WorkflowRun < ActiveRecord::Base
    include ShownInPacific
    self.table_name = "workflow_runs"
    serialize :inputs, coder: JsonCoder
  end
end
