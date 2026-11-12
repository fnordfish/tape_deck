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
      exclusions = @recorder.exclusions
      if tape.recording?
        tape.write(actual, recorded: {
          "exclude_tables" => @recorder.excluded_tables,
          "exclude_columns" => @recorder.excluded_columns,
          "databases" => exclusions
        })
      else
        verify(actual, exclusions)
      end
    end

    private

    # @return [Hash] the diff with the same shape as a tape read from disk
    def round_trip(diff) = YAML.safe_load(Tape.serialize(diff))

    # Compares the watched databases only. What is excluded now, but is on the tape, is dropped from both sides.
    def verify(actual, exclusions)
      recorded = tape.read.fetch("recorded")
      tape_exclusions = recorded.fetch("databases").slice(*exclusions.keys)
      report_schema_changes(recorded, tape_exclusions)
      filter = @filter.ignoring(newly_excluded(tape_exclusions, exclusions))
      expected = filter.apply(tape.read.fetch("diff").slice(*exclusions.keys))
      actual = filter.apply(actual)
      raise UnexpectedDiffError.new(tape, expected, actual) unless expected == actual
    end

    # The recorded exclude rules, applied to the current schema, must leave out what they did when recording.
    def report_schema_changes(recorded, tape_exclusions)
      return if @on_schema_change == :ignore

      now = @recorder.exclusions(
        exclude_tables: recorded.fetch("exclude_tables"),
        exclude_columns: recorded.fetch("exclude_columns")
      )
      changes = tape_exclusions.filter_map do |db_name, names|
        added = now.fetch(db_name) - names
        removed = names - now.fetch(db_name)
        "#{db_name}: added #{added.inspect}, removed #{removed.inspect}" unless added.empty? && removed.empty?
      end
      return if changes.empty?

      message = "schema changed since tape #{tape.file} was recorded, its exclude rules now match " \
        "other tables or columns (#{changes.join(", ")})"
      raise IncompatibleTapeError, message if @on_schema_change == :error

      warn "TapeDeck: #{message}"
    end

    # @return [Array<String>] patterns for what is excluded now, but was recorded on the tape
    # @raise [IncompatibleTapeError] if the tape left out something that is no longer excluded
    def newly_excluded(tape_exclusions, exclusions)
      exclusions.flat_map do |db_name, names|
        tape_names = tape_exclusions.fetch(db_name)
        no_longer_excluded = tape_names.reject { @recorder.excluded?(db_name, _1) }
        unless no_longer_excluded.empty?
          raise IncompatibleTapeError, "tape #{tape.file} left out #{no_longer_excluded.inspect} of #{db_name}, " \
            "which is no longer excluded. Re-record the tape."
        end

        (names - tape_names).map { Patterns.escape("#{db_name}.#{_1}") }
      end
    end
  end
end
