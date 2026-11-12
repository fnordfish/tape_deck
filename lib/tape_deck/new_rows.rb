# frozen_string_literal: true

module TapeDeck
  # Replaces the generated keys of inserted rows with placeholders like +"new shop.orders 1"+, numbered per table in
  # creation order, and references to those rows with the same placeholder. So a tape doesn't depend on where the
  # database's counters stand. Ids of rows that existed before stay as they are. See "New rows" in {TapeDeck}.
  #
  # @api private
  class NewRows
    # @param recorder [Recorder] tells the generated keys and references of tables
    # @param keep [Array<String>] patterns on +"<database>.<table>"+ for tables whose new ids are kept, see
    #   {Configuration#keep_new_ids}
    def initialize(recorder, keep: [])
      @recorder = recorder
      @keep = keep
    end

    # @param diff [Hash] a diff as stored on a tape
    # @return [Hash] the diff with placeholders
    def apply(diff)
      keys = @recorder.generated_keys(diff).to_h do |db_name, tables|
        [db_name, tables.reject { |table, _| Patterns.match?(@keep, "#{db_name}.#{table}") }]
      end
      placeholders = number(diff, keys)
      references = @recorder.references(diff)

      diff.to_h do |db_name, tables|
        replaced = tables.to_h do |table, changes|
          key = keys.dig(db_name, table)
          own_key = key ? {key => [db_name, table]} : {}
          columns = references.dig(db_name, table).to_h.merge(own_key)
          [table, replace(changes, columns, placeholders)]
        end
        [db_name, replaced]
      end
    end

    private

    # Auto increment keys grow, so sorting them gives the order the rows were created in.
    #
    # @return [Hash{String => Hash{String => Hash{Object => String}}}] database -> table -> key -> placeholder
    def number(diff, keys)
      keys.to_h do |db_name, tables|
        numbered = tables.to_h do |table, key|
          values = diff.dig(db_name, table, "inserted").map { _1.fetch(key) }.sort
          [table, values.each_with_index.to_h { |value, i| [value, "new #{db_name}.#{table} #{i + 1}"] }]
        end
        [db_name, numbered]
      end
    end

    # Rows that existed before keep their own ids, so only inserted rows and updated values can hold new ones.
    #
    # @param columns [Hash{String => Array(String, String)}] column -> +[database, table]+ whose new keys it can hold
    def replace(changes, columns, placeholders)
      swap = ->(column, value) do
        target = columns[column]
        (target && placeholders.dig(*target, value)) || value
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
