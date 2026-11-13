# frozen_string_literal: true

require "tape_deck"
require "tmpdir"
require "zlib"
require "securerandom"

require_relative "support/databases"
require_relative "support/server_examples"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # A filter that matches nothing must not pass silently
  config.fail_if_no_examples = true

  # Disable RSpec exposing methods globally on `Module` and `main`, and the `should` syntax. RSpec 4 has neither.
  if config.respond_to?(:disable_monkey_patching!)
    config.disable_monkey_patching!
    config.expect_with(:rspec) { |c| c.syntax = :expect }
  end

  config.include Databases

  # The MySQL integration specs need a server, see .devcontainer/compose.yml
  # Specs for a database server are tagged `server: "mysql"` or `server: "postgres"`, and only run when its URL is set.
  # One key, because RSpec 4 only excludes examples that match all exclusion filters.
  config.filter_run_excluding server: ->(server) { !ENV["TAPE_DECK_#{server.upcase}_URL"] }

  config.around do |example|
    Dir.mktmpdir("tape_deck") do |dir|
      TapeDeck.instance_variable_set(:@configuration, nil)
      TapeDeck.instance_variable_set(:@sessions, nil)
      TapeDeck.instance_variable_set(:@turned_off, nil)
      TapeDeck.configuration.tape_library_dir = dir
      example.run
    end
  end
end
