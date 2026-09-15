# frozen_string_literal: true

class CreateWorkflowSteps < ActiveRecord::Migration[7.2]
  def change
    create_table :workflow_steps do |t|
      t.integer :workflow_run_id, null: false
      t.string :kind, null: false
      t.integer :position, null: false
      t.string :name
      t.text :input
      t.text :output
      t.text :error
      t.string :session_id
      t.text :usage
      t.timestamps
    end
  end
end
