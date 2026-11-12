# frozen_string_literal: true

require "sequel"
require "bigdecimal"
require "date"
require "time"
require "digest"
require "yaml"
require "json"
require "fileutils"

require_relative "tape_deck/version"
require_relative "tape_deck/errors"
require_relative "tape_deck/configuration"
require_relative "tape_deck/tape"
require_relative "tape_deck/patterns"
require_relative "tape_deck/rows"
require_relative "tape_deck/new_rows"
require_relative "tape_deck/filter"
require_relative "tape_deck/session"
require_relative "tape_deck/adapters"
require_relative "tape_deck/recorder"

# Records what a block of code changes in several databases, and checks later runs against that recording.
# API, naming and flow inspired by the VCR gem.
#
# == Tapes
#
# A tape is one recording: the row-level diff that one action caused across all configured databases, stored as a YAML
# file in {Configuration#tape_library_dir}. It plays the role of VCR's cassette. Unlike a cassette it is never played
# back. The action always runs for real, and the tape is what its result is checked against.
#
# A tape cannot safely be played back, i.e. re-applied to a database. It holds the net effect of the action, not the
# statements that caused it or their order, so INSERT/UPDATE/DELETE statements generated from it can go wrong in many
# ways: foreign key constraints, generated columns, triggers.
#
# Next to the diff, a tape stores what was recorded: the recording rules, the watched databases, and the tables and
# columns the rules left out of each and the views they included.
#
#   recorded:
#     exclude_tables: [shop.sessions]
#     exclude_columns: ["*.created_at"]
#     include_views: [shop.order_totals]
#     databases:
#       shop:
#         excluded: [orders.created_at, sessions]
#         views: [order_totals]
#       billing:
#   diff:
#     shop:
#       orders:
#         inserted: [{ "id" => 42, "status" => "new", ... }]
#         updated:  [{ "key" => { "id" => 7 }, "changes" => { "status" => ["new", "paid"] } }]
#         deleted:  [...]
#
# == Lifecycle
#
# 1. *Insert* ({TapeDeck.insert_tape}): a snapshot of all watched databases is taken before the action runs. A tape to
#    be verified is read now, so a missing, broken or incompatible tape fails before the action runs.
# 2. The action runs.
# 3. *Eject* ({TapeDeck.eject_tape}): a second snapshot is taken and the diff between the two is captured. Then one of:
#    * *record*: the diff is written to the tape file, if the file is missing or the record mode is +:overwrite+
#    * *verify*: the diff is compared with the tape file, and {UnexpectedDiffError} is raised if they differ. See
#      "Excluding and ignoring" for narrowing what is compared.
#    * *discard*: nothing is written or compared, because the action itself failed
#
# {TapeDeck.use_tape} does all three steps around a block. See {Tape::RECORD_MODES} for the record modes.
#
# == Nested tapes
#
# Tapes can be nested. Each tape takes its own snapshots, so an outer tape also contains every change made while an
# inner tape was inserted. Tapes are ejected innermost first: {TapeDeck.eject_tape} always ejects the most recently
# inserted one. If an inner tape fails to verify inside an outer {TapeDeck.use_tape} block, the error propagates and
# the outer tape is discarded. With {TapeDeck.insert_tape} and {TapeDeck.eject_tape}, discarding is up to you.
#
#   TapeDeck.use_tape("checkout") do            # records the changes of both requests
#     client.post("/cart", ...)
#     TapeDeck.use_tape("checkout/payment") do  # records only the changes of this request
#       client.post("/pay", ...)
#     end
#   end
#
# == Selecting databases
#
# When recording, a tape watches all configured databases by default. Pass +databases:+ to watch only some of them.
# The others are neither read nor compared, so changes there go unnoticed.
#
# When verifying, a tape watches the databases it was recorded with by default. +databases:+ may select a subset of
# those, the rest of the tape is then not compared. Selecting a database the tape has no recording of raises
# {IncompatibleTapeError}.
#
#   TapeDeck.use_tape("checkout", databases: %w[shop billing]) { client.post("/checkout", ...) }
#
# == Patterns
#
# Tables are named +"<database>.<table>"+ and columns +"<database>.<table>.<column>"+, using the keys of
# {Configuration#databases}. All rules below are glob patterns on these names (<tt>File.fnmatch</tt>, where +*+ also
# matches dots), so +"*.created_at"+ matches that column in every table of every database, and +"shop.*"+ matches
# everything in +shop+.
#
# == New rows
#
# The ids a database hands out depend on where its counters stand, and those move with every insert, also with ones
# that were rolled back. So a tape doesn't store the generated keys of inserted rows. It numbers them per table in the
# order the rows were created, and stores placeholders like +"new shop.orders 1"+. Declared foreign keys to those rows
# get the same placeholder, in inserted rows and in updated values. Ids of rows that existed before stay as they are.
#
#   orders:
#     inserted:
#     - id: new shop.orders 1
#   items:
#     inserted:
#     - id: new shop.items 1
#       order_id: new shop.orders 1
#
# A key is generated if it is the single, auto increment primary key of its table. Rows are numbered in creation
# order, so creating the same rows in a different order fails verification. {Configuration#keep_new_ids} keeps the
# real ids of some tables.
#
# == Views
#
# Views are left out by default. A view holds no data of its own, so the changes of the tables behind it are already
# on the tape. {Configuration#include_views} adds views to snapshots, to also notice a changed view definition, or data
# a view reads from tables that are not recorded. Included views are read in full on every snapshot, and compared as a
# multiset of rows (+inserted+/+deleted+ only), because they have no primary key.
#
# Like the exclude rules, the tape stores the include rules and the views they matched. When verifying, a view on the
# tape that is no longer included is not compared. A view that is included now, but not on the tape, raises
# {IncompatibleTapeError}, unless the recorded rules match it too: then a schema change added it, see below.
#
# == Excluding and ignoring
#
# There are two ways to leave data out, and they act at different moments.
#
# *Exclude* means never recorded. {Configuration#exclude_tables} and {Configuration#exclude_columns} apply to every
# tape and are meant for noise no test cares about, like generated timestamps. Excluded data never reaches a tape. The
# tape stores what was left out, so the rules can change later: data that is excluded now, but is on the tape, is not
# compared. Data the tape left out, but that is no longer excluded, is missing from the tape, so verifying raises
# {IncompatibleTapeError} and the tape needs re-recording.
#
# The stored rules also reveal schema changes. When verifying, they are applied to the current schema again. If they
# leave out other tables or columns, or include other views than when recording, a matching table, column or view was
# added or removed.
# {Configuration#on_schema_change} decides whether that raises {IncompatibleTapeError}, warns, or is ignored.
#
# *Ignore* means recorded, but not compared. A tape always holds everything that is not excluded. When verifying, one
# use of a tape can narrow what is compared with +only:+ and +ignore:+. Both take one pattern or a list, and a pattern
# may name a whole database (+"billing.*"+), a table (+"shop.orders"+) or a column (+"shop.orders.status"+). With
# +only:+, everything else is ignored. +ignore:+ wins over +only:+. Neither has any effect while recording, so these
# rules can change without re-recording.
#
#   TapeDeck.use_tape("checkout", only: "shop.orders.status") { client.post("/checkout", ...) }
#   TapeDeck.use_tape("checkout", ignore: ["shop.orders.note", "billing.*"]) { client.post("/checkout", ...) }
#
# @example Configure
#   TapeDeck.configure do |c|
#     c.tape_library_dir = "spec/db_tapes"
#     c.databases = { "shop" => SHOP_DB, "billing" => BILLING_DB }
#     c.default_record_mode = :once
#     c.exclude_tables  "shop.sessions", "*.schema_migrations"
#     c.exclude_columns "*.created_at", "*.updated_at", "shop.users.last_seen_at"
#     c.include_views "shop.order_totals"
#     c.on_schema_change = :warn
#     c.configure_rspec_metadata!
#   end
#
# @example Record or verify a tape
#   TapeDeck.use_tape("checkout/creates_order") { client.post("/checkout", ...) }
#
# @example Watch only some databases
#   TapeDeck.use_tape("checkout/creates_order", databases: %w[shop billing]) { client.post("/checkout", ...) }
#   TapeDeck.use_tape("signup/sends_welcome_mail", databases: "mailer") { client.post("/signup", ...) }
#
# @example Compare only part of what is on the tape
#   TapeDeck.use_tape("checkout/creates_order", only: "shop.orders.status") { client.post("/checkout", ...) }
#   TapeDeck.use_tape("checkout/creates_order", ignore: "billing.invoices.number") { client.post("/checkout", ...) }
#
# @example RSpec, after +configure_rspec_metadata!+
#   RSpec.describe "Checkout" do
#     # tape "Checkout/creates an order", all databases
#     it "creates an order", :tape_deck do
#       client.post("/checkout", ...)
#     end
#
#     # only the shop database, custom tape name
#     it "reserves stock", tape_deck: { databases: %w[shop], tape_name: "checkout/stock" } do
#       client.post("/checkout", ...)
#     end
#
#     # compare only the order status
#     it "marks the order as paid", tape_deck: { only: "shop.orders.status" } do
#       client.post("/checkout", ...)
#     end
#
#     # re-record this tape on every run
#     it "creates an invoice", tape_deck: { record: :overwrite } do
#       client.post("/checkout", ...)
#     end
#   end
module TapeDeck
  class << self
    # @return [Configuration]
    def configuration = @configuration ||= Configuration.new

    # @yieldparam config [Configuration]
    # @return [void]
    def configure
      yield configuration
    end

    # Records or verifies the database changes made by the block. If the block raises, the tape is neither recorded
    # nor verified and the error propagates.
    #
    # @param name [String] tape name, e.g. +"checkout/creates_order"+
    # @param options [Hash] keyword options, see {.insert_tape}
    # @yield the action whose database changes are recorded
    # @return [Object] the block's return value
    # @raise [UnexpectedDiffError] if the changes do not match the tape
    # @raise [TapeLoadingError] if the tape must be verified but does not exist or cannot be read
    def use_tape(name, **options)
      insert_tape(name, **options)
      completed = false
      begin
        result = yield
        completed = true
        result
      ensure
        eject_tape(discard: !completed)
      end
    end

    # Starts a tape without a block: creates the tape and takes the "before" snapshot. Pair with {.eject_tape}. Tapes
    # may be nested, see "Nested tapes" in {TapeDeck}.
    #
    # Like +File.open+ without a block, this leaves the rest to you. {.use_tape} and the RSpec tag eject the tape in
    # any case, and discard it if the action fails. Here you have to:
    # * eject the tape with +discard: true+ if the action fails, otherwise the failed action is recorded or verified
    # * eject outer tapes yourself if ejecting an inner one raises. The inner one is ejected anyway, but the outer
    #   ones stay inserted, so usually eject them with +discard: true+.
    #
    # @param name [String] tape name, e.g. +"checkout/creates_order"+
    # @param databases [Array<String>, String, nil] names of the configured databases to watch, all of them if nil.
    #   See "Selecting databases" in {TapeDeck}.
    # @param only [Array<String>, String, nil] patterns for what to compare when verifying, everything if nil. See
    #   "Excluding and ignoring" in {TapeDeck}.
    # @param ignore [Array<String>, String, nil] patterns for what not to compare when verifying
    # @param options [Hash] keyword options, see {Tape#initialize}
    # @return [Tape]
    # @raise [ArgumentError] for a database name that is not configured
    # @raise (see Tape#initialize)
    # @example Insert and eject manually, the way {.use_tape} does
    #   TapeDeck.insert_tape("checkout/creates_order")
    #   begin
    #     client.post("/checkout", ...)
    #   rescue
    #     TapeDeck.eject_tape(discard: true)
    #     raise
    #   end
    #   TapeDeck.eject_tape
    def insert_tape(name, databases: nil, only: nil, ignore: nil, **options)
      tape = Tape.new(name, **options)
      recorder = Recorder.new(
        select_databases(tape_databases(tape, databases)),
        exclude_tables: configuration.excluded_tables,
        exclude_columns: configuration.excluded_columns,
        include_views: configuration.included_views
      )
      filter = Filter.new(only: only, ignore: ignore)
      new_rows = NewRows.new(recorder, keep: configuration.kept_new_ids)
      sessions.push(Session.new(tape, recorder, filter, on_schema_change: configuration.on_schema_change, new_rows: new_rows))
      tape
    end

    # Ejects the most recently inserted tape, i.e. the innermost one when tapes are nested: captures the diff, then
    # records it to the tape or verifies it against the tape. The tape is ejected even if this raises, see
    # {.insert_tape} for what that means for outer tapes.
    #
    # @param discard [Boolean] neither record nor verify, e.g. because the block failed
    # @return [Tape, nil] the ejected tape, or nil if none was inserted
    # @raise [UnexpectedDiffError] if verifying and the diff does not match the tape
    # @raise [IncompatibleTapeError] if verifying and the tape lacks data that is no longer excluded, or the schema
    #   changed, see {Configuration#on_schema_change}
    # @raise [TapeLoadingError] if verifying and the tape cannot be read, see {Tape#read}
    def eject_tape(discard: false)
      session = sessions.pop
      return unless session

      session.finish(discard: discard)
      session.tape
    end

    # @return [Tape, nil] the most recently inserted tape that has not been ejected yet
    def current_tape = sessions.last&.tape

    private

    def sessions = @sessions ||= []

    # When verifying, the tape must hold a recording of every watched database. Without a selection, these are the
    # databases the tape was recorded with. Reads the tape, so a broken one fails before the action runs.
    #
    # @param tape [Tape]
    # @param names [Array<String>, String, nil] the selection passed to {.insert_tape}
    # @return [Array<String>, nil] names of the databases to watch, all configured ones if nil
    # @raise [IncompatibleTapeError] if the tape has no recording of a selected database
    def tape_databases(tape, names)
      return names if tape.recording?

      recorded = tape.read.fetch("recorded").fetch("databases").keys
      names = Array(names || recorded).map(&:to_s)
      missing = names - recorded
      unless missing.empty?
        raise IncompatibleTapeError,
          "tape #{tape.file} has no recording of #{missing.inspect}, it was recorded with #{recorded.inspect}"
      end

      names
    end

    # @param names [Array<String>, String, nil]
    # @return [Hash{String => Sequel::Database}] the configured databases with these names, all of them if nil
    def select_databases(names)
      configured = configuration.databases.transform_keys(&:to_s)
      return configured if names.nil?

      names = Array(names).map(&:to_s)
      unknown = names - configured.keys
      unless unknown.empty?
        raise ArgumentError, "unknown databases #{unknown.inspect}, configured are #{configured.keys.inspect}"
      end

      configured.slice(*names)
    end
  end
end
