# frozen_string_literal: true

class CreateChannelThreads < ActiveRecord::Migration[7.2]
  def change
    create_table :channel_threads do |t|
      t.string :channel, null: false
      t.string :jid, null: false
      t.string :thread_id, null: false
      t.string :session_id, null: false
      t.datetime :last_message_at
      t.timestamps
    end
    add_index :channel_threads, %i[jid thread_id], unique: true
    add_index :channel_threads, :session_id
  end
end
