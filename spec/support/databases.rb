# frozen_string_literal: true

# In-memory SQLite databases, so the specs run without a database server.
module Databases
  # @return [Sequel::Database]
  def sqlite_db = Sequel.sqlite

  # Deletes all rows and resets auto increment, so the next action starts from the same state.
  def reset_tables(db, *tables)
    tables.each { db[_1].delete }
    db[:sqlite_sequence].where(name: tables.map(&:to_s)).delete
  end
end

# SQLite with checksums computed from all rows, so specs can check that unchanged tables are not read again.
class ChecksummingSQLite < TapeDeck::Adapters::SQLite
  def checksums(tables) = tables.to_h { [_1, Zlib.crc32(db[_1.to_sym].all.inspect)] }
end
