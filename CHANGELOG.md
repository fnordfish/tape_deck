# Changes

## 0.2.0.dev

- Fix: leaving a `use_tape` block early with `return`, `break` or `next` silently discarded the tape, so it was neither recorded nor verified
- Add: the RSpec integration works with RSpec 4.0.0.beta1, tested in CI next to RSpec 3
- Breaking: in the RSpec tag, `tape_name:` renames only the level it is set on, so an example's `tape_name: "x"` inside `describe "Checkout"` is the tape `Checkout/x`. A leading `/` gives the complete name, like `tape_name: "/orders/create"`.
- Change: `tape_deck:` options set on example groups are merged down to their examples, key by key. Before, an example's own options replaced all of its groups' options.
- Add: a user guide in `guide/`, published with the API docs: getting started, every setting, writing tests, choosing what is compared, new rows and ids, every error message explained, and a glossary. The README is short now and links to it.
- Fix: a tape that didn't match crashed with `NameError: uninitialized constant RSpec` outside of RSpec, like in Minitest or a script, instead of showing the diff
- Add: `TapeDeck.turn_off!`, `turn_on!`, `turned_on?` and `turned_off { }`, to run without TapeDeck. While it's off, `use_tape` only runs its block and tagged RSpec examples just run, without touching a database or a tape.

## 0.1.0

- Breaking: tapes recorded with 0.1.0.beta1 need re-recording. Their information section is now called `tape_deck`, and ids of new rows are stored as placeholders.
- Breaking: generated ids of inserted rows are stored as placeholders like `new shop.orders 1`, numbered per table in creation order, and so are declared foreign keys to them. Tapes no longer depend on where the database's counters stand. `keep_new_ids` keeps real ids.
  - `number_by_content` numbers a table's new rows by content, when creation order doesn't matter, like for an import
  - `references_to` adds references across databases and ones without a foreign key
  - `generated_keys` adds generated keys that aren't auto increment, like UUIDs
- Add: PostgreSQL support, and SQLite as a supported database. Database specific code lives in adapters, picked by Sequel's database type. Other databases Sequel supports read every table on every snapshot.
- Add: opt-in views with `include_views`
- Add: tapes store the TapeDeck version and the new-row numbering rules. Verifying uses the tape's numbering rules, not the current configuration.
- Add: the RSpec hook fails the suite when tagged examples would share a tape, like the same description in a loop
- Fix: the order of rows on a tape no longer depends on Ruby's `inspect` format, which changes between Ruby versions. Verifying also ignores the row order on the tape.
- Change: values of unknown types, like from Sequel's `pg_json` or `pg_array` extensions, become plain Hashes, Arrays or Strings
- Internal housekeeping
  - API docs on GitHub Pages, for `main` and every release
  - CI tests Ruby 3.2 to 4.0 and head, MySQL 8.4 and MariaDB 11.4 with `mysql2`, `trilogy` and `ruby-mysql`, and PostgreSQL 15 and 18
  - Gemfile.lock is no longer tracked

## 0.1.0.beta1

- First beta. The API and the tape format may still change.
