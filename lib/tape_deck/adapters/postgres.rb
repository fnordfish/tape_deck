# frozen_string_literal: true

module TapeDeck
  module Adapters
    # PostgreSQL. Sees the tables and views in the search path, like +Sequel::Database#tables+.
    #
    # PostgreSQL has no +CHECKSUM TABLE+. This computes one on the server: the row count, and the sum of 64 bits of
    # each row's MD5. Like +CHECKSUM TABLE+ it scans the table, but no rows are sent. The order of rows doesn't matter,
    # and the sum can't overflow, because it is a +numeric+.
    class Postgres < Base
      # Table alias in the checksum query. A short alias would mean a column instead, if the table had one with that
      # name.
      ROW = "tape_deck_row"

      # @param tables [Array<String>]
      # @return [Hash{String => String}] table -> checksum
      def checksums(tables)
        return {} if tables.empty?

        queries = tables.map do |table|
          "SELECT #{db.literal(table)} AS name, " \
            "count(*) || ':' || coalesce(sum(('x' || substr(md5(#{ROW}::text), 1, 16))::bit(64)::bigint), 0) AS sum " \
            "FROM #{db.literal(Sequel.identifier(table))} AS #{ROW}"
        end
        db.fetch(queries.join(" UNION ALL ")).to_h { |r| [r[:name], r[:sum]] }
      end
    end
  end
end
