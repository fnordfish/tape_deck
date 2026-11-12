# frozen_string_literal: true

module TapeDeck
  module Adapters
    # Works with any database Sequel supports. Subclasses add what their database does better.
    class Base
      # Database types of TIME columns, with or without fractional seconds. Sequel only types +time+ as +:time+, not
      # +time(6)+.
      TIME_DB_TYPE = /\Atime\b/i

      # @return [Sequel::Database]
      attr_reader :db

      # @param db [Sequel::Database]
      def initialize(db)
        @db = db
      end

      # Checksums tell which tables changed, so unchanged ones are not read again. A table without a checksum is read
      # on every snapshot, which is what this default does for all of them.
      #
      # @param tables [Array<String>]
      # @return [Hash{String => Object, nil}] table -> checksum, nil if unknown
      def checksums(tables)
        tables.to_h { [_1, nil] }
      end

      # Turns a column value into one that +YAML.safe_load+ reads back unchanged.
      #
      # @param value [Object] as returned by Sequel
      # @param column [Hash] column info from +db.schema+
      # @return [String, Integer, Float, Boolean, nil, Array, Hash]
      def serialize(value, column = {})
        case value
        when String then maybe_utf8(value)
        when Integer, Float, true, false, nil then value
        when BigDecimal then value.to_s("F")
        when Sequel::SQLTime then time_of_day(value)
        when Time then timestamp(value, column)
        when Date then value.iso8601
        else structured(value)
        end
      end

      private

      # Values of types not handled above, e.g. from Sequel extensions like +pg_json+ or +pg_array+. Hash-like and
      # array-like ones become plain Hashes and Arrays, everything else a String.
      def structured(value)
        if value.respond_to?(:to_hash)
          value.to_hash.to_h { |key, v| [key.to_s, serialize(v)] }
        elsif value.respond_to?(:to_ary)
          value.to_ary.map { serialize(_1) }
        else
          value.to_s
        end
      end

      # mysql2 returns TIME columns as a +Time+ on 2000-01-01, not as +Sequel::SQLTime+. Those keep their local time
      # of day, because converting them to UTC would shift the hour.
      def timestamp(value, column)
        if TIME_DB_TYPE.match?(column[:db_type].to_s)
          time_of_day(value)
        else
          value.utc.iso8601(6)
        end
      end

      def time_of_day(value) = value.strftime("%H:%M:%S.%6N")

      # Small binaries encode as hex. Large ones are shown as a digest so the YAML stays small.
      def bin(value)
        if value.bytesize <= 64
          "0x#{value.unpack1("H*")}"
        else
          "sha256:#{Digest::SHA256.hexdigest(value)}"
        end
      end

      # Binary columns arrive as ASCII-8BIT strings or +Sequel::SQL::Blob+, depending on the adapter. Ones that hold
      # valid UTF-8 become plain UTF-8 strings, because YAML would otherwise store them as base64 (+!binary+).
      # Everything else goes through {#bin}. Always returns a plain +String+, never a subclass, so YAML can read it.
      def maybe_utf8(value)
        binary = value.encoding == Encoding::BINARY || value.is_a?(Sequel::SQL::Blob)
        return String.new(value) unless binary

        utf8 = String.new(value, encoding: Encoding::UTF_8)
        if utf8.valid_encoding?
          utf8
        else
          bin(value)
        end
      end
    end
  end
end
