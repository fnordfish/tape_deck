# TapeDeck

Records what an action changes in your databases, and checks later runs against that recording.

[![Gem Version](https://img.shields.io/gem/v/tape_deck?include_prereleases)][gem]
[![Build Status](https://github.com/fnordfish/tape_deck/actions/workflows/main.yml/badge.svg)][ci]
[![API Docs](https://img.shields.io/badge/docs-API-blue)][docs]

**[API documentation][docs]**

> [!NOTE]
> TapeDeck is in beta. The API and the tape format may still change, which can mean re-recording your tapes.

You run a command or request against a black-box project. TapeDeck snapshots all configured databases before and after, and stores the row-level diff as a YAML file, a "tape". On later runs the same action must cause the same diff, so you notice when a project changes its behaviour after an update.

API, naming and flow are modelled on [VCR](https://github.com/vcr/vcr), with one big difference: a tape is never played back. The action always runs for real, and the tape is only what the result is compared against.

Works with [Sequel](https://sequel.jeremyevans.net) and MySQL or MariaDB (it uses `CHECKSUM TABLE` to skip unchanged tables). Tested with MySQL 8.4 and MariaDB 11.4, using the `mysql2` or `trilogy` adapter.

## Installation

Add this line to your application's Gemfile. While TapeDeck is in beta, the version requirement is needed, because Bundler skips prerelease versions without it:

```ruby
gem "tape_deck", "~> 0.1.0.beta1", group: :test
```

Or get it from [gem.coop](https://gem.coop):

```ruby
source "https://gem.coop/@fnordfish" do
  gem "tape_deck", "~> 0.1.0.beta1", group: :test
end
```

And then execute:

```console
bundle install
```

## Usage

```ruby
TapeDeck.configure do |c|
  c.tape_library_dir = "spec/db_tapes"
  c.databases = {"shop" => SHOP_DB, "billing" => BILLING_DB}
  c.default_record_mode = :once
  c.exclude_tables "shop.sessions", "*.schema_migrations"
  c.exclude_columns "*.created_at", "*.updated_at"
  c.configure_rspec_metadata!
end

TapeDeck.use_tape("checkout/creates_order") do
  client.post("/checkout", ...)
end
```

The first run writes `spec/db_tapes/checkout/creates_order.yml`:

```yaml
recorded:
  exclude_tables: [shop.sessions, "*.schema_migrations"]
  exclude_columns: ["*.created_at", "*.updated_at"]
  databases:
    shop:
      excluded: [orders.created_at, orders.updated_at, schema_migrations, sessions]
    billing:
      excluded: [invoices.created_at, schema_migrations]
diff:
  billing:
    invoices:
      inserted:
      - id: 7
        order_id: 42
  shop:
    orders:
      inserted:
      - id: 42
        status: new
    stock:
      updated:
      - key:
          id: 3
        changes:
          quantity:
          - 10
          - 9
```

`recorded` holds the exclude rules, the databases the tape watched, and what the rules left out of each.

Every later run verifies against it and raises `TapeDeck::UnexpectedDiffError` with a diff when the changes differ.

### Record modes

* `:once` records a missing tape, and verifies an existing one (default)
* `:verify` only verifies. A missing tape raises `TapeDeck::TapeLoadingError`. Use this in CI, with `c.default_record_mode = :verify`.
* `:overwrite` always records, replacing an existing tape

### RSpec

After `configure_rspec_metadata!`, tag examples with `:tape_deck`. The tape is named after the example's description, unless you pass `tape_name:`. A failing example neither records nor verifies its tape.

```ruby
RSpec.describe "Checkout" do
  it "creates an order", :tape_deck do
    client.post("/checkout", ...)
  end

  it "reserves stock", tape_deck: {databases: %w[shop], tape_name: "checkout/stock"} do
    client.post("/checkout", ...)
  end

  it "marks the order as paid", tape_deck: {only: "shop.orders.status"} do
    client.post("/checkout", ...)
  end
end
```

### Excluding and ignoring

Names are `"<database>.<table>"` and `"<database>.<table>.<column>"`, matched as globs.

* `exclude_tables` / `exclude_columns` (configuration): never recorded. Meant for noise like timestamps. Excluding more later is fine, existing tapes just stop comparing it. Excluding less means re-recording, because the tapes lack that data (`TapeDeck::IncompatibleTapeError`).
* `only:` / `ignore:` (per use of a tape): recorded, but not compared. Can change without re-recording.

Since a tape stores its exclude rules, verifying also notices schema changes: when the rules now match tables or columns that were added or removed since recording, it raises `TapeDeck::IncompatibleTapeError`. Set `c.on_schema_change = :warn` to only print a warning, or `:ignore`.

Primary key columns are never excluded, because rows are matched by them. Tables without a primary key are compared as a multiset of rows.

### Things to know

* Your databases need the same starting state on every run. Auto increment ids and existing rows end up on the tape.
* Anything the action does asynchronously must finish inside the block, or only part of it is captured.
* When verifying, a tape watches the databases it was recorded with. `databases:` can narrow that down, but can't add a database the tape has no recording of.

The [API docs][docs] have the full story.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

The default specs run against in-memory SQLite databases that fake MySQL's `CHECKSUM TABLE`, so you don't need a MySQL server. For the real thing, open the devcontainer, it comes with MySQL.

Please also see [DEVELOPMENT.md](DEVELOPMENT.md) for design decisions and open questions.

## Contributing

Bug reports and pull requests are welcome on GitHub at <https://github.com/fnordfish/tape_deck>. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/fnordfish/tape_deck/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

[gem]: https://rubygems.org/gems/tape_deck
[ci]: https://github.com/fnordfish/tape_deck/actions/workflows/main.yml
[docs]: https://fnordfish.github.io/tape_deck/docs/main/
