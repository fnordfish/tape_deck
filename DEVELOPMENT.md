# Development Guidelines

- Keep it simple.
- Keep the module boundaries clean, each piece has one job.

## Design

| Piece | Job |
| --- | --- |
| `Configuration` | Plain settings: `tape_library_dir`, `databases`, `default_record_mode`, `on_schema_change`, exclude patterns, RSpec hook |
| `Tape` | File-like. Knows its name, path and mode (`recording?` / `verifying?`), can `read` and `write(diff, tape_deck:)`. Never touches a database |
| `Recorder` | Observes databases: `snapshot` and `diff`. Knows nothing about tapes or configuration |
| `Adapters` | The database specific parts of a snapshot: checksums to skip unchanged tables, and turning column values into plain YAML values. Picked by `db.database_type`, `Adapters::Base` for other databases |
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
- **A tape stores everything that shapes its content**, in its `tape_deck` section: the TapeDeck version that recorded it, every recording rule (exclude, include, numbering), the watched databases, and the resolved names the exclude and include rules matched in each. A tape must be understandable and verifiable on its own. Per-use options (`only:`, `ignore:`) and behavior settings (record mode, `on_schema_change`) are not stored, they don't shape the content.
  - A tape must cover the run that verifies it: the watched databases are a subset of the recorded ones, and everything the tape left out is still excluded under the current rules. What is excluded now but on the tape is dropped from both sides before comparing.
  - Schema changes: the recorded patterns, applied to the current schema, must resolve to the recorded names. A difference means a matching table or column was added or removed. `on_schema_change` decides between error, warning and nothing.
- **New rows get placeholders**, `"new <database>.<table> <n>"`, numbered per table in creation order (sorted auto increment ids). Only single, auto increment primary keys count as generated, so natural keys like a SKU stay visible. Declared single column foreign keys get the same placeholder, in inserted rows and in updated values. Ids of rows that existed before stay literal. `NewRows` runs on both sides, after the diff is captured and before it is recorded or verified. Verifying uses the numbering rules stored on the tape, not the configuration, because numbering only changes how ids are written. (Exclude and include rules are different: they decide which data is on the tape, so verifying uses the current ones and checks they fit the tape.)
  - `references_to` adds references by column pattern, across databases too, and wins over a declared foreign key. `generated_keys` adds primary keys that aren't auto increment. Keys that aren't integers have no creation order, so their tables are always numbered by content.
  - `number_by_content` tables are sorted by their JSON without the key, after the tables they reference, so references are placeholders already. A reference to a row without a placeholder yet (self references, cycles) counts as `"new <database>.<table>"` only, because its id isn't stable. Ties are broken by creation order.
- **Primary key columns are never excluded**, even if a pattern matches, because rows are matched by them.
- **Snapshots reuse unchanged tables.** The adapter computes a checksum per table before and after: `CHECKSUM TABLE` on MySQL, the row count plus a sum of row hashes on PostgreSQL. A table whose checksum is unchanged reuses the first snapshot object, and `diff` skips it by identity (`equal?`). Without a checksum (SQLite, other databases), a table is read on every snapshot.
- **Tables without a primary key** are compared as a multiset of rows (inserted / deleted only).
- **Row order never depends on `inspect`**, whose format changes between Ruby versions (3.4 changed `Hash#inspect`). Rows are sorted by their JSON (`TapeDeck::Rows`), and verifying sorts both sides before comparing, so the order on a tape is for reading only.
- **Unknown value types become plain values.** Values from Sequel extensions like `pg_json` or `pg_array` are hash-like or array-like objects, which `YAML.safe_load` can't read back. `Adapters::Base#serialize` turns them into plain Hashes and Arrays, and any other unknown type into a String.
- **PostgreSQL sees the search path only**, like `db.tables`, so names stay `"<database>.<table>"` for every database.
- **Views are opt-in** (`include_views`), because table diffs already cover their data. Included views are always read in full (no checksum tells whether a view changed) and compared as a multiset. The tape stores the include patterns and the resolved views per database. A view no longer included is not compared, one included by changed rules raises `IncompatibleTapeError`, one added by a schema change is reported like any schema change and not compared.
- **Binary values**: valid UTF-8 becomes a plain UTF-8 string, anything else is hex up to 64 bytes and a `sha256:` digest above that. Always a plain `String`, never a subclass, so `YAML.safe_load` can read the tape.
- **TIME columns** are stored as a time of day, recognized by their database type (`Adapters::Base::TIME_DB_TYPE`), because Sequel types `time` as `:time` but not `time(6)`. `mysql2` returns them as a `Time` on 2000-01-01, which would otherwise be stored as a timestamp.

## Code style

- [Standard](https://github.com/standardrb/standard), run with `bundle exec rake standard`
- YARD docs, brief, where useful. Private helpers only get a comment when the name is not enough. Keep `yard stats` at 100 percent.
- Comment lines up to 120 characters
- Prefer `if ... else` over the ternary operator unless trivial
- Extract dense expressions into named variables, constants or methods

## Testing

- `bundle exec rake spec` runs everything: the SQLite specs, then the MySQL specs once per adapter if `TAPE_DECK_MYSQL_URL` is set, and the PostgreSQL specs if `TAPE_DECK_POSTGRES_URL` is set
- `bundle exec rake spec:sqlite` needs no server. In-memory SQLite through Sequel, using the real SQLite adapter.
- `bundle exec rake spec:mysql2` / `spec:trilogy` run `spec/integration/mysql_spec.rb` (tagged `:mysql`) with that adapter
- `bundle exec rake spec:postgres` runs `spec/integration/postgres_spec.rb` (tagged `:postgres`)

Both server specs include the shared examples in `spec/support/server_examples.rb`, and add their own value types. The adapters' checksum queries are also covered by the SQLite run, through Sequel's mock databases (`spec/tape_deck/adapters_spec.rb`).

`TAPE_DECK_MYSQL_URL` and `TAPE_DECK_POSTGRES_URL` are server URLs without a database, e.g. `mysql2://root:tape_deck@mysql` and `postgres://postgres:tape_deck@postgres`. The MySQL adapter tasks replace the scheme with their own. The server specs create and drop `tape_deck_shop` and `tape_deck_billing`.

The devcontainer (`.devcontainer/`) has Ruby, MySQL 8.4 and PostgreSQL 18, with both URLs already set. Without VS Code:

    docker compose -f .devcontainer/compose.yml run --rm app sh -c "bundle install && bundle exec rake spec"

Set `MYSQL_IMAGE` for another MySQL server, e.g. `MYSQL_IMAGE=mariadb:11.4`, `POSTGRES_IMAGE` for another PostgreSQL, e.g. `POSTGRES_IMAGE=postgres:15`, and `RUBY_IMAGE` for another Ruby, e.g. `RUBY_IMAGE=ruby:3.2`.

CI runs the default task on every supported Ruby and on Ruby head. In the devcontainer setup, on the oldest and newest supported Ruby, it runs `spec:mysql2` and `spec:trilogy` against MySQL 8.4 and MariaDB 11.4, and `spec:postgres` against PostgreSQL 15 and 18.

The database adapters live in the optional `mysql` and `postgres` Gemfile groups (`BUNDLE_WITH=mysql:postgres`), because `mysql2` and `pg` may need client libraries to install.

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

Ruby 3.2 to 4.0. On Ruby 3.2 and 4.0: MySQL 8.4 and MariaDB 11.4, each with the `mysql2` and `trilogy` adapters, and PostgreSQL 15 and 18. SQLite with every supported Ruby. Other servers and versions may work, but are untested.

## Roadmap and open questions

- Binary data that happens to be valid UTF-8 (short hashes, UUIDs) is shown as text
- Checksums scan the whole table (`CHECKSUM TABLE`, the PostgreSQL checksum query). Fine for test databases, worth measuring for large ones.
- PostgreSQL schemas other than the search path
