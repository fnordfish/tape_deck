# frozen_string_literal: true

require "tape_deck"
require "tmpdir"
require "zlib"

require_relative "support/databases"
require_relative "support/server_examples"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # A filter that matches nothing must not pass silently
  config.fail_if_no_examples = true

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include Databases

  # The MySQL integration specs need a server, see .devcontainer/compose.yml
  config.filter_run_excluding :mysql unless ENV["TAPE_DECK_MYSQL_URL"]
  config.filter_run_excluding :postgres unless ENV["TAPE_DECK_POSTGRES_URL"]

  config.around do |example|
    Dir.mktmpdir("tape_deck") do |dir|
      TapeDeck.instance_variable_set(:@configuration, nil)
      TapeDeck.instance_variable_set(:@sessions, nil)
      TapeDeck.configuration.tape_library_dir = dir
      example.run
    end
  end
end
