# frozen_string_literal: true

module TapeDeck
  # Replaces the generated keys of inserted rows with placeholders like +"new shop.orders 1"+, numbered per table, and
  # references to those rows with the same placeholder. So a tape doesn't depend on where the database's counters
  # stand. Ids of rows that existed before stay as they are. See "New rows" in {TapeDeck}.
  #
  # @api private
  class NewRows
    # @param recorder [Recorder] tells the generated keys and references of tables
    # @param keep [Array<String>] patterns on +"<database>.<table>"+ for tables whose new ids are kept, see
    #   {Configuration#keep_new_ids}
    # @param by_content [Array<String>] patterns on +"<database>.<table>"+ for tables whose new rows are numbered by
    #   content instead of creation order, see {Configuration#number_by_content}
    # @param generated_keys [Array<String>] patterns for more generated keys, see {Configuration#generated_keys}
    # @param references [Hash{String => Array<String>}] more references, see {Configuration#references_to}
    def initialize(recorder, keep: [], by_content: [], generated_keys: [], references: {})
      @recorder = recorder
      @keep = keep
      @by_content = by_content
      @generated_keys = generated_keys
      @references = references
    end

    # @param diff [Hash] a diff as stored on a tape
    # @return [Hash] the diff with placeholders
    def apply(diff)
      keys = @recorder.generated_keys(diff, patterns: @generated_keys).to_h do |db_name, tables|
        [db_name, tables.reject { |table, _| Patterns.match?(@keep, "#{db_name}.#{table}") }]
      end
      references = @recorder.references(diff, patterns: @references)
      columns = diff.to_h do |db_name, tables|
        [db_name, tables.keys.to_h { [_1, placeholder_columns(db_name, _1, keys, references)] }]
      end
      placeholders = number(diff, keys, columns)

      diff.to_h do |db_name, tables|
        [db_name, tables.to_h { |table, changes| [table, replace(changes, columns.dig(db_name, table), placeholders)] }]
      end
    end

    private

    # @return [Hash{String => Array(String, String)}] column -> +[database, table]+ whose new keys it can hold: the
    #   table's own key, and its references
    def placeholder_columns(db_name, table, keys, references)
      key = keys.dig(db_name, table)
      own_key = if key
        {key => [db_name, table]}
      else
        {}
      end
      references.dig(db_name, table).to_h.merge(own_key)
    end

    # Tables numbered by content go after the ones they reference, so their content can hold those placeholders.
    # Keys that are not integers, like UUIDs, tell nothing about creation order, so their tables are numbered by
    # content too.
    #
    # @return [Hash{Array(String, String) => Hash{Object => String}}] +[database, table]+ -> key -> placeholder
    def number(diff, keys, columns)
      tables = keys.flat_map { |db_name, db_keys| db_keys.map { |table, key| [db_name, table, key] } }
      new_keys = tables.to_h do |db_name, table, key|
        [[db_name, table], diff.dig(db_name, table, "inserted").map { _1.fetch(key) }]
      end
      by_content, by_creation = tables.partition do |db_name, table, _|
        content?(db_name, table) || !new_keys.fetch([db_name, table]).all?(Integer)
      end

      placeholders = {}
      by_creation.each do |db_name, table, key|
        rows = diff.dig(db_name, table, "inserted").sort_by { _1.fetch(key) }
        placeholders[[db_name, table]] = assign(db_name, table, rows.map { _1.fetch(key) })
      end
      pending = by_content
      until pending.empty?
        ready = pending.reject do |db_name, table, _|
          references_pending?(columns.dig(db_name, table), [db_name, table], pending)
        end
        ready = pending if ready.empty? # a cycle, see #content
        ready.each do |db_name, table, key|
          rows = diff.dig(db_name, table, "inserted")
          sorted = rows.sort_by { [content(_1, key, columns.dig(db_name, table), placeholders, new_keys), _1.fetch(key)] }
          placeholders[[db_name, table]] = assign(db_name, table, sorted.map { _1.fetch(key) })
        end
        pending -= ready
      end
      placeholders
    end

    def content?(db_name, table) = Patterns.match?(@by_content, "#{db_name}.#{table}")

    def references_pending?(columns, own, pending)
      pending_tables = pending.map { |db_name, table, _| [db_name, table] } - [own]
      columns.values.any? { pending_tables.include?(_1) }
    end

    # The row without its key, as JSON. A reference to a new row that has no placeholder yet (the table references
    # itself, or tables reference each other) only says which table it points to, because its id is not stable.
    def content(row, key, columns, placeholders, new_keys)
      values = row.except(key).to_h do |column, value|
        target = columns[column]
        replaced = if target.nil?
          value
        elsif placeholders.key?(target)
          placeholders.dig(target, value) || value
        elsif new_keys.fetch(target, []).include?(value)
          "new #{target.join(".")}"
        else
          value
        end
        [column, replaced]
      end
      JSON.generate(values, allow_nan: true)
    end

    def assign(db_name, table, values)
      values.each_with_index.to_h { |value, i| [value, "new #{db_name}.#{table} #{i + 1}"] }
    end

    # Rows that existed before keep their own ids, so only inserted rows and updated values can hold new ones.
    #
    # @param columns [Hash{String => Array(String, String)}] column -> +[database, table]+ whose new keys it can hold
    def replace(changes, columns, placeholders)
      swap = ->(column, value) do
        target = columns[column]
        (target && placeholders.dig(target, value)) || value
      end
      changes.to_h do |section, entries|
        replaced = case section
        when "inserted"
          entries.map { |row| row.to_h { |column, value| [column, swap.call(column, value)] } }
        when "updated"
          entries.map do |update|
            values = update.fetch("changes").to_h { |column, pair| [column, pair.map { swap.call(column, _1) }] }
            update.merge("changes" => values)
          end
        else
          entries
        end
        [section, replaced]
      end
    end
  end
end
