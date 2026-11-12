# frozen_string_literal: true

module TapeDeck
  module Adapters
    # MySQL and MariaDB. Uses +CHECKSUM TABLE+, so unchanged tables are not read again.
    class MySQL < Base
      # @param tables [Array<String>]
      # @return [Hash{String => Integer, nil}] table -> checksum
      def checksums(tables)
        return {} if tables.empty?

        list = tables.map { db.literal(Sequel.identifier(_1)) }.join(", ")
        db.fetch("CHECKSUM TABLE #{list}").to_h do |r|
          _db_name, table = r[:Table].split(".", 2) # MySQL reports "<db>.<table>"
          [table, r[:Checksum]]
        end
      end
    end
  end
end
