# frozen_string_literal: true

module TapeDeck
  # A stable order for rows, so tapes come out the same on every Ruby version. Rows hold plain values only, see
  # {Adapters::Base#serialize}, and the JSON format pins down how those are written. +inspect+ does not, it changed
  # in Ruby 3.4.
  #
  # @api private
  module Rows
    # @param rows [Array<Hash>]
    # @return [Array<Hash>] sorted by their JSON
    def self.sort(rows)
      rows.sort_by { JSON.generate(_1, allow_nan: true) }
    end
  end
end
