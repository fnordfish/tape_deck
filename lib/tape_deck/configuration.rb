# frozen_string_literal: true

module TapeDeck
  # Global settings, set through {TapeDeck.configure}.
  class Configuration
    # Supported values for {#on_schema_change}:
    # [+:error+]  raise {IncompatibleTapeError}
    # [+:warn+]   print a warning and verify anyway
    # [+:ignore+] verify anyway
    SCHEMA_CHANGE_ACTIONS = %i[error warn ignore].freeze

    # @return [String] directory tapes are read from and written to (default +"spec/db_tapes"+)
    attr_accessor :tape_library_dir

    # @return [Hash{String => Sequel::Database}] databases to diff, keyed by the name used in tapes and patterns
    attr_accessor :databases

    # Record mode of tapes that don't set their own +record:+. One of {Tape::RECORD_MODES} (default +:once+). Set it
    # to +:verify+ in CI, so a missing tape fails the run.
    #
    # @return [Symbol]
    attr_reader :default_record_mode

    # What to do when verifying finds that the schema changed since recording: the recorded exclude rules leave out
    # other tables or columns than they did then. One of {SCHEMA_CHANGE_ACTIONS} (default +:error+).
    #
    # @return [Symbol]
    attr_reader :on_schema_change

    # @return [Array<String>] patterns added with {#exclude_tables}
    attr_reader :excluded_tables

    # @return [Array<String>] patterns added with {#exclude_columns}
    attr_reader :excluded_columns

    # @return [Array<String>] patterns added with {#include_views}
    attr_reader :included_views

    # @return [Array<String>] patterns added with {#keep_new_ids}
    attr_reader :kept_new_ids

    # @return [Array<String>] patterns added with {#number_by_content}
    attr_reader :numbered_by_content

    # @return [Array<String>] patterns added with {#generated_keys}
    attr_reader :generated_key_columns

    # @return [Hash{String => Array<String>}] patterns added with {#references_to}, by referenced table
    attr_reader :reference_columns

    def initialize
      @tape_library_dir = "spec/db_tapes"
      @databases = {}
      @default_record_mode = :once
      @on_schema_change = :error
      @excluded_tables = []
      @excluded_columns = []
      @included_views = []
      @kept_new_ids = []
      @numbered_by_content = []
      @generated_key_columns = []
      @reference_columns = {}
    end

    # @param mode [Symbol] one of {Tape::RECORD_MODES}
    # @raise [ArgumentError] for an unknown record mode
    def default_record_mode=(mode)
      Tape.validate_record_mode(mode)
      @default_record_mode = mode
    end

    # @param action [Symbol] one of {SCHEMA_CHANGE_ACTIONS}
    # @raise [ArgumentError] for an unknown action
    def on_schema_change=(action)
      unless SCHEMA_CHANGE_ACTIONS.include?(action)
        raise ArgumentError, "invalid schema change action #{action.inspect}, use one of #{SCHEMA_CHANGE_ACTIONS.inspect}"
      end

      @on_schema_change = action
    end

    # Leaves matching tables out of snapshots entirely, so they are never recorded.
    #
    # @param patterns [Array<String>] globs on +"<database>.<table>"+
    # @return [void]
    # @example
    #   c.exclude_tables "shop.sessions", "*.schema_migrations"
    def exclude_tables(*patterns)
      @excluded_tables.concat(patterns.map(&:to_s))
    end

    # Drops matching columns from every row before diffing, so they are never recorded. Primary key columns are never
    # dropped, because rows are matched by them.
    #
    # @param patterns [Array<String>] globs on +"<database>.<table>.<column>"+
    # @return [void]
    # @example
    #   c.exclude_columns "*.created_at", "*.updated_at"
    def exclude_columns(*patterns)
      @excluded_columns.concat(patterns.map(&:to_s))
    end

    # Adds matching views to snapshots. Views are left out by default, because the changes of the tables behind them
    # are recorded anyway. Include them to also notice changed view definitions, or data a view reads from tables
    # that are not recorded. Included views are read in full on every snapshot, and compared as a multiset of rows,
    # because they have no primary key. {#exclude_columns} applies to their columns, {#exclude_tables} does not.
    #
    # @param patterns [Array<String>] globs on +"<database>.<view>"+
    # @return [void]
    # @example
    #   c.include_views "shop.order_totals", "billing.*"
    def include_views(*patterns)
      @included_views.concat(patterns.map(&:to_s))
    end

    # Keeps the generated ids of rows inserted into matching tables, instead of replacing them with placeholders.
    # See "New rows" in {TapeDeck}.
    #
    # @param patterns [Array<String>] globs on +"<database>.<table>"+
    # @return [void]
    # @example
    #   c.keep_new_ids "shop.audit_log"
    def keep_new_ids(*patterns)
      @kept_new_ids.concat(patterns.map(&:to_s))
    end

    # Numbers the new rows of matching tables by their content instead of the order they were created in, so creating
    # the same rows in a different order still verifies. For example an import, whose order doesn't matter. Rows with
    # the same content are numbered in creation order. See "New rows" in {TapeDeck}.
    #
    # @param patterns [Array<String>] globs on +"<database>.<table>"+
    # @return [void]
    # @example
    #   c.number_by_content "shop.imported_products"
    def number_by_content(*patterns)
      @numbered_by_content.concat(patterns.map(&:to_s))
    end

    # Marks matching primary keys as generated, like auto increment ones are: keys that the database or the
    # application fills in, for example UUIDs. Their new rows get placeholders, see "New rows" in {TapeDeck}. Keys that
    # are not integers have no creation order, so their rows are numbered by content.
    #
    # @param patterns [Array<String>] globs on +"<database>.<table>.<column>"+
    # @return [void]
    # @example
    #   c.generated_keys "shop.tokens.id", "*.uuid"
    def generated_keys(*patterns)
      @generated_key_columns.concat(patterns.map(&:to_s))
    end

    # Marks matching columns as holding keys of a table, like a declared foreign key does. Needed for references
    # across databases, and ones without a foreign key. Overrides a declared foreign key of the same column.
    #
    # @param table [String] +"<database>.<table>"+ whose keys the columns hold
    # @param patterns [Array<String>] globs on +"<database>.<table>.<column>"+
    # @return [void]
    # @example
    #   c.references_to "shop.orders", "billing.invoices.order_id", "*.last_order_id"
    def references_to(table, *patterns)
      (@reference_columns[table.to_s] ||= []).concat(patterns.map(&:to_s))
    end

    # Wraps RSpec examples tagged +:tape_deck+ in a tape. The tape is named after the example's description hierarchy
    # unless +tape_name:+ is given. When the example fails, the tape is neither recorded nor verified.
    #
    # @return [void]
    # @example
    #   it "creates an order", :tape_deck do ... end
    #   it "creates an order", tape_deck: { record: :overwrite, tape_name: "orders/create" } do ... end
    #   it "creates an order", tape_deck: { databases: %w[shop] } do ... end
    def configure_rspec_metadata!
      ::RSpec.configure do |config|
        config.around(:each, :tape_deck) do |example|
          options = Hash.try_convert(example.metadata[:tape_deck]) || {} # a bare :tape_deck tag is `true`
          name = options[:tape_name] || Configuration.rspec_tape_name(example)

          TapeDeck.insert_tape(name, **options.except(:tape_name))
          example.run
          example_failed = !example.exception.nil?
          TapeDeck.eject_tape(discard: example_failed)
        end
      end
    end

    # @param example [RSpec::Core::Example]
    # @return [String] the example's description hierarchy, e.g. +"Checkout/creates an order"+
    # @api private
    def self.rspec_tape_name(example)
      group_descriptions = example.example_group.parent_groups.reverse.map(&:description)
      [*group_descriptions, example.description].join("/")
    end
  end
end
