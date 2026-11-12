# frozen_string_literal: true

require_relative "adapters/base"
require_relative "adapters/mysql"
require_relative "adapters/postgres"
require_relative "adapters/sqlite"

module TapeDeck
  # The database specific parts of taking snapshots: telling which tables changed, and turning column values into
  # plain YAML values. Everything else goes through Sequel and works the same for every database.
  module Adapters
    # Adapters by +Sequel::Database#database_type+.
    BY_DATABASE_TYPE = {mysql: MySQL, postgres: Postgres, sqlite: SQLite}.freeze

    # @param db [Sequel::Database]
    # @return [Base] the adapter for the database type. {Base} for other databases, which works, but reads every
    #   table on every snapshot.
    def self.for(db)
      BY_DATABASE_TYPE.fetch(db.database_type, Base).new(db)
    end
  end
end
