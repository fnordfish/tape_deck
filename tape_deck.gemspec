# frozen_string_literal: true

require_relative "lib/tape_deck/version"

Gem::Specification.new do |spec|
  spec.name = "tape_deck"
  spec.version = TapeDeck::VERSION
  spec.authors = ["Robert Schulze"]
  spec.email = ["robert@dotless.de"]

  spec.summary = "Records what an action changes in your databases, and checks later runs against it."
  spec.description = "Snapshots your databases around an action and stores the row-level diff as a YAML tape. " \
    "Later runs of the same action are verified against the tape, so you notice when a change or update " \
    "alters what gets written. VCR-style API, works with Sequel and MySQL, MariaDB, PostgreSQL or SQLite."
  spec.homepage = "https://github.com/fnordfish/tape_deck"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://fnordfish.github.io/tape_deck/docs/v#{spec.version}/"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .standard.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "bigdecimal"
  spec.add_dependency "sequel", "~> 5.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
