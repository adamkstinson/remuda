# frozen_string_literal: true

class CreateChannelSessions < ActiveRecord::Migration[7.2]
  def change
    create_table :channel_sessions do |t|
      t.string :channel, null: false
      t.string :jid, null: false
      t.text :data
      t.timestamps
    end
    add_index :channel_sessions, %i[channel jid], unique: true
  end
end
