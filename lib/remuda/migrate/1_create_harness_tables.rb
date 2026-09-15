# frozen_string_literal: true

class CreateHarnessTables < ActiveRecord::Migration[7.2]
  def change
    create_table :workflow_runs do |t|
      t.string :workflow, null: false
      t.string :status, null: false
      t.string :trigger
      t.text :inputs
      t.string :exception_class
      t.text :exception_message
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    create_table :schedules do |t|
      t.string :workflow, null: false
      t.string :cron, null: false
      t.string :timezone, default: "UTC"
      t.text :inputs
      t.boolean :paused, default: false, null: false
      t.datetime :last_occurrence
      t.datetime :next_occurrence
      t.timestamps
    end
  end
end
