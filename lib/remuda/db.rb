# frozen_string_literal: true

require "fileutils"
require "active_record"

module Remuda
  module Db
    def self.connect(agent_dir)
      path = File.join(File.expand_path(agent_dir), ".remuda", "db", "remuda.sqlite3")
      FileUtils.mkdir_p(File.dirname(path))
      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3",
        database: path
      )
      ActiveRecord::Base.connection.execute("PRAGMA journal_mode = WAL")
      migrate!
    end

    def self.migrate!
      migrations_path = File.expand_path("migrate", __dir__)
      ActiveRecord::Migration.verbose = false
      ActiveRecord::MigrationContext.new(migrations_path).migrate
    end
  end
end
