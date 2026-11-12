# Development Guidelines

- Keep it simple.
- Keep the module boundaries clean, each piece has one job.

## Design

| Piece | Job |
| --- | --- |
| `Configuration` | Plain settings: `tape_library_dir`, `databases`, `default_record_mode`, `on_schema_change`, exclude patterns, RSpec hook |
| `Tape` | File-like. Knows its name, path and mode (`recording?` / `verifying?`), can `read` and `write(diff, recorded:)`. Never touches a database |
| `Recorder` | Observes databases: `snapshot` and `diff`. Knows nothing about tapes or configuration |
| `Filter` | Narrows a diff to what one use of a tape wants compared (`only:` / `ignore:`). `@api private` |
| `Session` | One run of one tape: "before" snapshot on creation, `finish` captures the diff and records or verifies. `@api private` |

`TapeDeck.insert_tape` is the only place that wires these together. `TapeDeck.use_tape` wraps insert and eject around a block. Sessions are kept on a stack, so tapes can be nested.

Decisions made on purpose. Please don't undo them without discussing first:

- **Exclude vs ignore.** `exclude_tables` / `exclude_columns` (configuration) mean never recorded. `only:` / `ignore:` (per tape use) mean recorded but not compared, applied to both sides when verifying and not at all when recording. There is deliberately no global verify-time ignore.
- **Record modes** are `:once`, `:verify`, `:overwrite`. Renamed from VCR's `:once`, `:none`, `:all`.
- **Vocabulary.** "record", "verify", "discard", "capture". Not "playback", not "compare" as a mode name.
- **Errors** live directly under `TapeDeck` (`Error`, `TapeLoadingError`, `IncompatibleTapeError`, `UnexpectedDiffError`), not in an `Errors` module.
- **Manual `insert_tape` / `eject_tape` work like `File.open` without a block**: no automatic tear down. The caller discards a tape whose action failed, and ejects outer tapes when an inner eject raises. `use_tape` and the RSpec tag do both.
- **Options are keywords.** Unknown keywords raise.
- **A tape stores what was recorded**: the exclude patterns (once, they are global), the watched databases, and the resolved names (`<table>`, `<table>.<column>`) the patterns left out of each.
  - A tape must cover the run that verifies it: the watched databases are a subset of the recorded ones, and everything the tape left out is still excluded under the current rules. What is excluded now but on the tape is dropped from both sides before comparing.
  - Schema changes: the recorded patterns, applied to the current schema, must resolve to the recorded names. A difference means a matching table or column was added or removed. `on_schema_change` decides between error, warning and nothing.
- **Primary key columns are never excluded**, even if a pattern matches, because rows are matched by them.
- **Snapshots reuse unchanged tables.** `CHECKSUM TABLE` runs before and after. A table whose checksum is unchanged reuses the first snapshot object, and `diff` skips it by identity (`equal?`).
- **Tables without a primary key** are compared as a multiset of rows (inserted / deleted only).
- **Binary values**: valid UTF-8 becomes a plain UTF-8 string, anything else is hex up to 64 bytes and a `sha256:` digest above that. Always a plain `String`, never a subclass, so `YAML.safe_load` can read the tape.
- **TIME columns** are stored as a time of day, recognized by their database type (`Recorder::TIME_DB_TYPE`), because Sequel types `time` as `:time` but not `time(6)`. `mysql2` returns them as a `Time` on 2000-01-01, which would otherwise be stored as a timestamp.

## Code style

- [Standard](https://github.com/standardrb/standard), run with `bundle exec rake standard`
- YARD docs, brief, where useful. Private helpers only get a comment when the name is not enough. Keep `yard stats` at 100 percent.
- Comment lines up to 120 characters
- Prefer `if ... else` over the ternary operator unless trivial
- Extract dense expressions into named variables, constants or methods

## Testing

- `bundle exec rake spec` runs everything: the fake specs, then the MySQL specs once per adapter if `TAPE_DECK_MYSQL_URL` is set
- `bundle exec rake spec:fake` needs no server. In-memory SQLite through Sequel, `spec/support/fake_mysql.rb` answers `CHECKSUM TABLE`, everything else is real Sequel.
- `bundle exec rake spec:mysql2` / `spec:trilogy` run `spec/integration/mysql_spec.rb` (tagged `:mysql`) with that adapter

`TAPE_DECK_MYSQL_URL` is a server URL without a database, e.g. `mysql2://root:tape_deck@mysql`. The adapter tasks replace its scheme with their own. The MySQL specs create and drop `tape_deck_shop` and `tape_deck_billing`.

The devcontainer (`.devcontainer/`) has Ruby and MySQL 8.4, with `TAPE_DECK_MYSQL_URL` already set. Without VS Code:

    docker compose -f .devcontainer/compose.yml run --rm app sh -c "bundle install && bundle exec rake spec"

The server is MySQL 8.4 by default. Set `MYSQL_IMAGE` for another one, e.g. `MYSQL_IMAGE=mariadb:11.4`. Ruby is 4.0, set `RUBY_IMAGE` for another one, e.g. `RUBY_IMAGE=ruby:3.2`.

CI runs the default task on every supported Ruby and on Ruby head. It runs `spec:mysql2` and `spec:trilogy` in the devcontainer setup, against MySQL 8.4 and MariaDB 11.4, on the oldest and newest supported Ruby.

The adapters live in the optional `mysql` Gemfile group (`BUNDLE_WITH=mysql`), because `mysql2` needs the MySQL client library to install.

## Docs

- `bundle exec yard doc` builds the docs into `doc/`, `bundle exec yard server -r` serves them while you edit
- `bundle exec rake docs:pages` builds `main` and every `v*` tag into `_site/docs/<ref>`, from their commits, not the working tree. It empties `_site` first.

The Docs workflow runs `docs:pages` on every version tag, and on pushes to `main` that change a file the docs are built from (the `paths` in `.github/workflows/pages.yml`, keep it in sync with `.yardopts`), and force-pushes `_site` as a single commit to the `gh-pages` branch, published at <https://fnordfish.github.io/tape_deck/docs/> (`main/`, `v0.1.0/`, ...). `latest/` redirects to the newest release, or the newest prerelease until there is one. GitHub Pages must serve that branch (Settings, Pages, Source: "Deploy from a branch", `gh-pages`, `/ (root)`). The branch is not deployed with `actions/deploy-pages`, because that deploys a commit only once, and a release pushes `main` and the tag for the same commit.

## Releasing

Releases go to rubygems.org and to the `@fnordfish` namespace on [gem.coop](https://gem.coop).

1. Bump `TapeDeck::VERSION` and add a CHANGELOG entry
2. `GEM_COOP_API_KEY=<push key> bundle exec rake release`

`release` tags, pushes to rubygems.org, then runs `release:gem_coop`. If the gem.coop push fails, run `bundle exec rake release:gem_coop` again on its own. Push keys come from <https://gem.coop/user/push_keys/new>.

## Tested against

Ruby 3.2 to 4.0. MySQL 8.4 and MariaDB 11.4, each with the `mysql2` and `trilogy` adapters, on Ruby 3.2 and 4.0. Other servers and versions may work, but are untested.

## Roadmap and open questions

- Replace new auto increment ids with stable placeholders, so tapes don't depend on the starting state
- Views are not snapshotted (`db.tables` skips them)
- Binary data that happens to be valid UTF-8 (short hashes, UUIDs) is shown as text
- `CHECKSUM TABLE` scans the whole table. Fine for test databases, worth measuring for large ones.
