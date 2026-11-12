# frozen_string_literal: true

module TapeDeck
  # Glob matching for table and column names, see "Patterns" in {TapeDeck}.
  #
  # @api private
  module Patterns
    # @param patterns [Array<String>]
    # @param name [String] +"<database>.<table>"+ or +"<database>.<table>.<column>"+
    # @return [Boolean] whether any of the patterns matches the name
    def self.match?(patterns, name)
      patterns.any? { File.fnmatch?(_1, name, File::FNM_EXTGLOB) }
    end

    # @param name [String]
    # @return [String] a pattern that matches only this name
    def self.escape(name)
      name.gsub(/[*?\[\]{}\\]/) { "\\#{_1}" }
    end
  end
end
