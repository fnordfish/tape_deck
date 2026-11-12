# frozen_string_literal: true

module TapeDeck
  module Adapters
    # SQLite. Has no cheap way to tell whether a table changed, so every table is read on every snapshot. For a local
    # database file that is usually fast enough.
    class SQLite < Base
    end
  end
end
