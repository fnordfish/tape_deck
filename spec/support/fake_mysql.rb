# frozen_string_literal: true

# In-memory SQLite databases that answer MySQL's +CHECKSUM TABLE+, so the whole recorder runs without a MySQL server.
module FakeMySQL
  # @param name [String] database name reported by +CHECKSUM TABLE+
  # @return [Sequel::Database]
  def fake_mysql(name = "shop")
    db = Sequel.sqlite
    db.define_singleton_method(:fetch) do |sql, *args, &block|
      checksum_table = sql.match(/\ACHECKSUM TABLE (.+)\z/)
      return super(sql, *args, &block) unless checksum_table

      checksum_table[1].scan(/`([^`]+)`/).flatten.map do |table|
        {Table: "#{name}.#{table}", Checksum: Zlib.crc32(self[table.to_sym].all.inspect)}
      end
    end
    db
  end

  # Deletes all rows and resets auto increment, so the next action starts from the same state.
  def reset_tables(db, *tables)
    tables.each { db[_1].delete }
    db[:sqlite_sequence].where(name: tables.map(&:to_s)).delete
  end
end
