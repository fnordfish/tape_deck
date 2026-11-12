# frozen_string_literal: true

module TapeDeck
  # One run of one tape: takes the "before" snapshot when created, and on {#finish} captures the diff and records it
  # to the tape or verifies it against the tape.
  #
  # @api private
  class Session
    # @return [Tape]
    attr_reader :tape

    # @param tape [Tape]
    # @param recorder [Recorder]
    # @param filter [Filter] narrows what is compared when verifying
    # @param on_schema_change [Symbol] see {Configuration#on_schema_change}
    def initialize(tape, recorder, filter, on_schema_change: :error)
      @tape = tape
      @recorder = recorder
      @filter = filter
      @on_schema_change = on_schema_change
      @before = recorder.snapshot
    end

    # @param discard [Boolean] neither record nor verify, e.g. because the block failed
    # @return [void]
    # @raise [UnexpectedDiffError] if verifying and the diff does not match the tape
    # @raise [IncompatibleTapeError] if verifying and the tape lacks data that is no longer excluded, or the schema
    #   changed and {Configuration#on_schema_change} is +:error+
    # @raise [TapeLoadingError] if verifying and the tape cannot be read, see {Tape#read}
    def finish(discard: false)
      return if discard

      after = @recorder.snapshot(previous: @before)
      actual = round_trip(@recorder.diff(@before, after))
      current = @recorder.resolve
      if tape.recording?
        tape.write(actual, recorded: {
          "exclude_tables" => @recorder.excluded_tables,
          "exclude_columns" => @recorder.excluded_columns,
          "include_views" => @recorder.included_views,
          "databases" => current
        })
      else
        verify(actual, current)
      end
    end

    private

    # @return [Hash] the diff with the same shape as a tape read from disk
    def round_trip(diff) = YAML.safe_load(Tape.serialize(diff))

    # Compares the watched databases only. What the current rules leave out, but is on the tape, is dropped from both
    # sides. So are views a schema change added.
    #
    # @param current [Hash] what the current rules resolve to, see {Recorder#resolve}
    def verify(actual, current)
      recorded = tape.read.fetch("recorded")
      on_tape = recorded.fetch("databases").slice(*current.keys)
      by_recorded_rules = @recorder.resolve(
        exclude_tables: recorded.fetch("exclude_tables"),
        exclude_columns: recorded.fetch("exclude_columns"),
        include_views: recorded.fetch("include_views")
      )
      report_schema_changes(on_tape, by_recorded_rules)
      ignored = newly_excluded(on_tape, current) + changed_views(on_tape, current, by_recorded_rules)
      filter = @filter.ignoring(ignored)
      expected = filter.apply(tape.read.fetch("diff").slice(*current.keys))
      actual = filter.apply(actual)
      raise UnexpectedDiffError.new(tape, expected, actual) unless expected == actual
    end

    # The recorded rules, applied to the current schema, must leave out and include what they did when recording.
    def report_schema_changes(on_tape, by_recorded_rules)
      return if @on_schema_change == :ignore

      changes = on_tape.flat_map do |db_name, lists|
        Tape::DATABASE_LISTS.filter_map do |list|
          now = by_recorded_rules.fetch(db_name).fetch(list)
          added = now - lists.fetch(list)
          removed = lists.fetch(list) - now
          "#{db_name} #{list}: added #{added.inspect}, removed #{removed.inspect}" unless added.empty? && removed.empty?
        end
      end
      return if changes.empty?

      message = "schema changed since tape #{tape.file} was recorded, its recording rules now match " \
        "other tables, columns or views (#{changes.join(", ")})"
      raise IncompatibleTapeError, message if @on_schema_change == :error

      warn "TapeDeck: #{message}"
    end

    # @return [Array<String>] patterns for what is excluded now, but was recorded on the tape
    # @raise [IncompatibleTapeError] if the tape left out something that is no longer excluded
    def newly_excluded(on_tape, current)
      current.flat_map do |db_name, lists|
        tape_names = on_tape.fetch(db_name).fetch("excluded")
        no_longer_excluded = tape_names.reject { @recorder.excluded?(db_name, _1) }
        unless no_longer_excluded.empty?
          raise IncompatibleTapeError, "tape #{tape.file} left out #{no_longer_excluded.inspect} of #{db_name}, " \
            "which is no longer excluded. Re-record the tape."
        end

        (lists.fetch("excluded") - tape_names).map { Patterns.escape("#{db_name}.#{_1}") }
      end
    end

    # A view on the tape that is no longer included is not compared. Neither is one included now because a schema
    # change added it, which {#report_schema_changes} reports.
    #
    # @return [Array<String>] patterns for the views not to compare
    # @raise [IncompatibleTapeError] if a view is included now by changed rules, so the tape lacks it
    def changed_views(on_tape, current, by_recorded_rules)
      current.flat_map do |db_name, lists|
        tape_views = on_tape.fetch(db_name).fetch("views")
        added = lists.fetch("views") - tape_views
        newly_included = added - by_recorded_rules.fetch(db_name).fetch("views")
        unless newly_included.empty?
          raise IncompatibleTapeError, "tape #{tape.file} has no recording of the views #{newly_included.inspect} " \
            "of #{db_name}, which are included now. Re-record the tape."
        end

        no_longer_included = tape_views - lists.fetch("views")
        (no_longer_included + added).map { Patterns.escape("#{db_name}.#{_1}") }
      end
    end
  end
end
