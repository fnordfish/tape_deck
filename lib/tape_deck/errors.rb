# frozen_string_literal: true

module TapeDeck
  # Base class for all TapeDeck errors.
  class Error < StandardError; end

  # Raised when a tape must be verified but its file does not exist, is not valid YAML or does not hold a diff.
  class TapeLoadingError < Error; end

  # Raised when a tape cannot verify this run: it has no recording of a watched database, or something it left out is
  # no longer excluded, so the tape lacks that data. Re-record the tape.
  class IncompatibleTapeError < Error; end

  # Raised when the block changed the databases differently than the tape says.
  class UnexpectedDiffError < Error
    # @return [Tape] the tape that did not match
    attr_reader :tape

    # @return [Hash] the diff stored on the tape
    attr_reader :expected

    # @return [Hash] the diff the block caused
    attr_reader :actual

    # @param tape [Tape]
    # @param expected [Hash] the diff stored on the tape
    # @param actual [Hash] the diff the block caused
    def initialize(tape, expected, actual)
      @tape = tape
      @expected = expected
      @actual = actual
      super("DB diff does not match tape #{tape.file}\n#{describe}")
    end

    # RSpec's differ if available, otherwise one that prints both sides. Loaded on first use.
    #
    # @return [#call] +(actual, expected) -> String+
    # @api private
    def self.differ
      @differ ||= begin
        # The differ expects rspec/support loaded, which RSpec does, but other test frameworks and scripts don't
        require "rspec/support"
        require "rspec/support/differ"
        ::RSpec::Support::Differ.new.method(:diff)
      rescue LoadError
        ->(actual, expected) { "--- expected\n#{expected}\n--- actual\n#{actual}" }
      end
    end

    private

    def describe
      self.class.differ.call(Tape.serialize(actual), Tape.serialize(expected))
    end
  end
end
