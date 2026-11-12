# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in tape_deck.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "standard", "~> 1.3"

gem "sqlite3"
gem "yard"

# Only needed for the database server specs, see .devcontainer/compose.yml
group :mysql, optional: true do
  gem "mysql2"
  gem "trilogy"
end

group :postgres, optional: true do
  gem "pg"
end
