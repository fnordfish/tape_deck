# frozen_string_literal: true

module TapeDeck
  # Snapshot of one table.
  #
  # @!attribute [r] checksum
  #   @return [Integer, nil] result of +CHECKSUM TABLE+
  # @!attribute [r] pk
  #   @return [Array<String>] primary key columns, empty if the table has none
  # @!attribute [r] rows
  #   @return [Hash] +{ [pk values] => row }+ for tables with a primary key, +{ row => occurrence count }+ for tables
  #     without one
  # @api private
  TableSnap = Data.define(:checksum, :pk, :rows)

  # Takes snapshots of all configured databases and diffs them. Used by {Session}, but usable on its own when you don't
  # need tape files.
  class Recorder
    # Database types of TIME columns, with or without fractional seconds. Sequel only types +time+ as +:time+, not
    # +time(6)+.
    TIME_DB_TYPE = /\Atime\b/i

    # @return [Array<String>] see {Configuration#exclude_tables}
    attr_reader :excluded_tables

    # @return [Array<String>] see {Configuration#exclude_columns}
    attr_reader :excluded_columns

    # @param dbs [Hash{String => Sequel::Database}]
    # @param exclude_tables [Array<String>] see {Configuration#exclude_tables}
    # @param exclude_columns [Array<String>] see {Configuration#exclude_columns}
    def initialize(dbs, exclude_tables: [], exclude_columns: [])
      @dbs = dbs
      @excluded_tables = exclude_tables
      @excluded_columns = exclude_columns
    end

    # @yield the action whose database changes are recorded
    # @return [Hash] the diff, see {#diff}
    def record
      before = snapshot
      yield
      diff(before, snapshot(previous: before))
    end

    # Reads all tables that are not excluded. With +previous:+, tables whose +CHECKSUM TABLE+ is unchanged reuse the
    # previous snapshot, so only changed tables are read again.
    #
    # @param previous [Hash, nil] an earlier result of this method
    # @return [Hash{String => Hash{String => TableSnap}}]
    def snapshot(previous: nil)
      @dbs.to_h do |name, db|
        tables = checksums(db, name).to_h do |table, sum|
          prev = previous&.dig(name, table)
          unchanged = prev && sum && prev.checksum == sum
          snap = if unchanged
            prev
          else
            dump(db, name, table, sum)
          end
          [table, snap]
        end
        [name, tables]
      end
    end

    # Rows are matched by primary key. Tables without one are compared as a multiset of rows (+inserted+/+deleted+
    # only). Unchanged tables and empty sections are omitted.
    #
    # @param before [Hash] result of {#snapshot}
    # @param after [Hash] result of {#snapshot}
    # @return [Hash{String => Hash{String => Hash}}] database -> table -> +"inserted"+ / +"updated"+ / +"deleted"+
    def diff(before, after)
      before.keys.sort.each_with_object({}) do |db_name, out|
        changed_tables = tables_diff(before.fetch(db_name), after.fetch(db_name))
        out[db_name] = changed_tables unless changed_tables.empty?
      end
    end

    # What exclude rules leave out of each database, by default the ones this recorder was created with. Reads the
    # current schema, so other rules show what they would have left out.
    #
    # @param exclude_tables [Array<String>] table patterns, see {Configuration#exclude_tables}
    # @param exclude_columns [Array<String>] column patterns, see {Configuration#exclude_columns}
    # @return [Hash{String => Array<String>}] database -> sorted +"<table>"+ and +"<table>.<column>"+ names
    def exclusions(exclude_tables: @excluded_tables, exclude_columns: @excluded_columns)
      @dbs.to_h do |db_name, db|
        tables = db.tables.map(&:to_s)
        table_names = tables.select { Patterns.match?(exclude_tables, "#{db_name}.#{_1}") }
        column_names = (tables - table_names).flat_map do |table|
          excluded_column_names(db_name, table, db.schema(table.to_sym), exclude_columns).map { "#{table}.#{_1}" }
        end
        [db_name, (table_names + column_names).sort]
      end
    end

    # @param db_name [String]
    # @param name [String] +"<table>"+ or +"<table>.<column>"+, as returned by {#exclusions}
    # @return [Boolean] whether the exclude rules leave this table or column out. Says nothing about primary keys,
    #   which are never left out.
    def excluded?(db_name, name)
      patterns = if name.include?(".")
        @excluded_columns
      else
        @excluded_tables
      end
      Patterns.match?(patterns, "#{db_name}.#{name}")
    end

    private

    # Primary key columns are never excluded, because rows are matched by them.
    #
    # @return [Array<Symbol>]
    def excluded_column_names(db_name, table, schema, patterns = @excluded_columns)
      schema.filter_map do |col, info|
        col if !info[:primary_key] && Patterns.match?(patterns, "#{db_name}.#{table}.#{col}")
      end
    end

    # Diffs one database. A table missing on one side (created or dropped by the action) counts as empty there.
    def tables_diff(before, after)
      (before.keys | after.keys).sort.each_with_object({}) do |table, out|
        b, a = before[table], after[table]
        next if b.equal?(a) # checksum unchanged, snapshot reused

        changes = table_diff(b || empty_like(a), a || empty_like(b))
        out[table] = changes unless changes.empty?
      end
    end

    # @return [Hash{String => Integer, nil}] table name -> checksum
    def checksums(db, name)
      tables = db.tables.map(&:to_s).sort.reject { excluded?(name, _1) }
      return {} if tables.empty?

      list = tables.map { db.literal(Sequel.identifier(_1)) }.join(", ")
      db.fetch("CHECKSUM TABLE #{list}").to_h do |r|
        _db_name, table = r[:Table].split(".", 2) # MySQL reports "<db>.<table>"
        [table, r[:Checksum]]
      end
    end

    # @return [TableSnap]
    def dump(db, name, table, sum)
      schema = db.schema(table.to_sym)
      pk = schema.select { |_, i| i[:primary_key] }.map(&:first)
      types = schema.to_h { |col, i| [col, column_type(i)] }

      drop = excluded_column_names(name, table, schema)

      ds = db[table.to_sym]
      ds = ds.order(*pk) unless pk.empty?

      rows = {}
      ds.each do |r|
        row = r.except(*drop).to_h { |col, v| [col.to_s, serialize(v, types[col])] }
        if pk.empty?
          rows[row] = rows.fetch(row, 0) + 1
        else
          rows[pk.map { serialize(r[_1], types[_1]) }] = row
        end
      end
      TableSnap.new(checksum: sum, pk: pk.map(&:to_s), rows: rows)
    end

    # @param info [Hash] column info from +db.schema+
    # @return [Symbol, nil] Sequel's column type, +:time+ for all TIME columns, see {TIME_DB_TYPE}
    def column_type(info)
      if TIME_DB_TYPE.match?(info[:db_type].to_s)
        :time
      else
        info[:type]
      end
    end

    def empty_like(snap) = TableSnap.new(checksum: nil, pk: snap.pk, rows: {})

    def table_diff(b, a)
      if b.pk.empty?
        multiset_diff(b.rows, a.rows)
      else
        keyed_diff(b, a)
      end
    end

    def keyed_diff(b, a)
      inserted = (a.rows.keys - b.rows.keys).map { a.rows[_1] }
      deleted = (b.rows.keys - a.rows.keys).map { b.rows[_1] }
      updated = (a.rows.keys & b.rows.keys).filter_map do |k|
        old, new = b.rows[k], a.rows[k]
        next if old == new

        {"key" => a.pk.zip(k).to_h, "changes" => changed_columns(old, new)}
      end
      compact("inserted" => inserted, "updated" => updated, "deleted" => deleted)
    end

    # @return [Hash{String => Array(Object, Object)}] column -> +[old, new]+ for columns whose value differs
    def changed_columns(old, new)
      (old.keys | new.keys).each_with_object({}) do |col, changes|
        changes[col] = [old[col], new[col]] unless old[col] == new[col]
      end
    end

    def multiset_diff(b, a)
      inserted, deleted = [], []
      (b.keys | a.keys).each do |row|
        delta = a.fetch(row, 0) - b.fetch(row, 0)
        if delta.positive?
          inserted.concat([row] * delta)
        elsif delta.negative?
          deleted.concat([row] * delta.abs)
        end
      end
      compact("inserted" => sort_rows(inserted), "deleted" => sort_rows(deleted))
    end

    def sort_rows(rows) = rows.sort_by(&:inspect)
    def compact(h) = h.reject { |_, v| v.empty? }

    # Converts a column value to a YAML-stable scalar. +type+ is the column type from +db.schema+.
    def serialize(v, type = nil)
      case v
      when String then maybe_utf8(v)
      when BigDecimal then v.to_s("F")
      when Sequel::SQLTime then time_of_day(v)
      when Time then timestamp(v, type)
      when Date then v.iso8601
      else v # Integer, Float, true/false, nil
      end
    end

    # mysql2 returns TIME columns as a +Time+ on 2000-01-01, not as +Sequel::SQLTime+. Those keep their local time of
    # day, because converting them to UTC would shift the hour.
    def timestamp(v, type)
      if type == :time
        time_of_day(v)
      else
        v.utc.iso8601(6)
      end
    end

    def time_of_day(v) = v.strftime("%H:%M:%S.%6N")

    # Small binaries encode as hex. Large ones are shown as a digest so the YAML stays small.
    def bin(v)
      if v.bytesize <= 64
        "0x#{v.unpack1("H*")}"
      else
        "sha256:#{Digest::SHA256.hexdigest(v)}"
      end
    end

    # BINARY, VARBINARY and BLOB columns arrive as ASCII-8BIT strings (or Sequel::SQL::Blob, depending on the adapter).
    # Ones that hold valid UTF-8 become plain UTF-8 strings, because YAML would otherwise store them as base64
    # (+!binary+). Everything else goes through {#bin}.
    def maybe_utf8(v)
      binary = v.encoding == Encoding::BINARY || v.is_a?(Sequel::SQL::Blob)
      return v unless binary

      utf8 = String.new(v, encoding: Encoding::UTF_8)
      if utf8.valid_encoding?
        utf8
      else
        bin(v)
      end
    end
  end
end
