# frozen_string_literal: true

module TapeDeck
  # Narrows a diff to what one use of a tape wants compared, see "Excluding and ignoring" in {TapeDeck}.
  #
  # @api private
  class Filter
    # @param only [Array<String>, String, nil] patterns to keep, everything if nil
    # @param ignore [Array<String>, String, nil] patterns to drop
    def initialize(only: nil, ignore: nil)
      @only = Array(only).map(&:to_s)
      @ignore = Array(ignore).map(&:to_s)
    end

    # @param patterns [Array<String>] more patterns to drop
    # @return [Filter] a copy that also drops these
    def ignoring(patterns)
      Filter.new(only: @only, ignore: @ignore + patterns)
    end

    # @param diff [Hash] a diff as stored on a tape
    # @return [Hash] the diff without ignored columns, and without rows, tables and databases left empty by that
    def apply(diff)
      return diff if @only.empty? && @ignore.empty?

      diff.each_with_object({}) do |(db_name, tables), out|
        kept_tables = tables.each_with_object({}) do |(table, changes), kept|
          kept_changes = filter_table("#{db_name}.#{table}", changes)
          kept[table] = kept_changes unless kept_changes.empty?
        end
        out[db_name] = kept_tables unless kept_tables.empty?
      end
    end

    private

    def filter_table(table_name, changes)
      kept = {
        "inserted" => filter_rows(table_name, changes.fetch("inserted", [])),
        "updated" => filter_updates(table_name, changes.fetch("updated", [])),
        "deleted" => filter_rows(table_name, changes.fetch("deleted", []))
      }
      kept.reject { |_, entries| entries.empty? }
    end

    def filter_rows(table_name, rows)
      kept = rows.map { |row| filter_columns(table_name, row) }
      kept.reject(&:empty?)
    end

    # The "key" of an update is kept as it is, because it identifies the row.
    def filter_updates(table_name, updates)
      updates.filter_map do |update|
        changes = filter_columns(table_name, update.fetch("changes"))
        update.merge("changes" => changes) unless changes.empty?
      end
    end

    def filter_columns(table_name, columns)
      columns.select { |column, _| compare?(table_name, "#{table_name}.#{column}") }
    end

    # A column is addressed by a pattern for the column itself or one for its whole table.
    def compare?(table_name, column_name)
      names = [table_name, column_name]
      return false if names.any? { Patterns.match?(@ignore, _1) }

      @only.empty? || names.any? { Patterns.match?(@only, _1) }
    end
  end
end
