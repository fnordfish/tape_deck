# TapeDeck

Records what an action changes in your databases, and checks later runs against that recording.

[![Gem Version](https://img.shields.io/gem/v/tape_deck)][gem]
[![Build Status](https://github.com/fnordfish/tape_deck/actions/workflows/main.yml/badge.svg)][ci]
[![API Docs](https://img.shields.io/badge/docs-API-blue)][docs]

- **[Guide](guide/index.md)**
- **[API documentation][docs]**

You run a command or request against a black-box project. TapeDeck snapshots all configured databases before and after, and stores the row-level diff as a YAML file, a "tape". On later runs the same action must cause the same diff, so you notice when a project changes its behaviour after an update.

API, naming and flow are modelled on [VCR](https://github.com/vcr/vcr), with one big difference: a tape is never played back. The action always runs for real, and the tape is only what the result is compared against.

Works with [Sequel](https://sequel.jeremyevans.net) and MySQL, MariaDB, PostgreSQL or SQLite. Needs Ruby 3.2 or newer. The RSpec integration works with RSpec 3 and RSpec 4.0.0.beta1.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "tape_deck", group: :test
```

Or get it from [gem.coop](https://gem.coop):

```ruby
source "https://gem.coop/@fnordfish" do
  gem "tape_deck", group: :test
end
```

And then execute:

```console
bundle install
```

## Quick start

Configure TapeDeck, for example in `spec/support/tape_deck.rb`:

```ruby
require "tape_deck"

TapeDeck.configure do |c|
  c.tape_library_dir = File.expand_path("../db_tapes", __dir__)
  c.databases = {"shop" => SHOP_DB, "billing" => BILLING_DB}
  c.exclude_columns "*.created_at", "*.updated_at"
  c.configure_rspec_metadata!
end
```

Tag an example:

```ruby
RSpec.describe "Checkout" do
  it "creates an order", :tape_deck do
    client.post("/checkout", product: "book")
  end
end
```

The first run records the tape `spec/db_tapes/Checkout/creates_an_order.yml`:

```yaml
tape_deck:
  version: 0.1.0
  exclude_columns: ["*.created_at", "*.updated_at"]
  databases:
    shop:
      excluded: [orders.created_at, orders.updated_at]
    billing:
diff:
  shop:
    orders:
      inserted:
      - id: new shop.orders 1
        product: book
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

Every later run verifies against it, and fails with a diff when the changes differ. New rows get placeholders like `new shop.orders 1` instead of their ids, because ids depend on where the database's counters stand.

Without RSpec, put a tape around any block:

```ruby
TapeDeck.use_tape("checkout/creates_order") do
  client.post("/checkout", product: "book")
end
```

## Learn more

The [guide](guide/index.md) explains everything step by step, without assuming you're fluent in Ruby:

1. [Getting started](guide/getting-started.md)
2. [Configuration](guide/configuration.md): every setting, what it does, its default
3. [Writing tests](guide/writing-tests.md): RSpec tags on examples and groups, tape names, options, tapes without RSpec
4. [Choosing what is compared](guide/what-is-compared.md): excluding, ignoring, views
5. [New rows and ids](guide/new-rows.md)
6. [When a tape fails](guide/when-a-tape-fails.md): reading failures, and every error message explained
7. [Glossary](guide/glossary.md)

## Databases

| Database | Tested with | Unchanged tables |
| --- | --- | --- |
| MySQL, MariaDB | MySQL 8.4 and MariaDB 11.4, `mysql2`, `trilogy` and `ruby-mysql` gems | skipped, using `CHECKSUM TABLE` |
| PostgreSQL | PostgreSQL 15 and 18, `pg` adapter | skipped, using a checksum computed on the server |
| SQLite | `sqlite3` adapter | read again on every snapshot |

Telling unchanged tables apart still scans them on the server, but saves reading their rows. Other databases Sequel supports should work too, and read every table on every snapshot.

PostgreSQL tables are seen through the search path, like Sequel's `db.tables` does, usually the `public` schema. Tables in other schemas are not recorded.

## Things to know

* Rows that exist before the action end up on the tape when it changes them, so your databases need the same starting rows on every run. Where the id counters stand doesn't matter.
* Anything the action does asynchronously must finish inside the block, or only part of it is captured.
* Until 1.0, a minor version (0.2, 0.3, ...) may change the tape format. The CHANGELOG says when tapes need re-recording.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

The default specs run against in-memory SQLite databases, so you don't need a database server. For MySQL, MariaDB and PostgreSQL, open the devcontainer, it comes with both servers.

Please also see [DEVELOPMENT.md](DEVELOPMENT.md) for design decisions and open questions.

## Contributing

Bug reports and pull requests are welcome on GitHub at <https://github.com/fnordfish/tape_deck>. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/fnordfish/tape_deck/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

[gem]: https://rubygems.org/gems/tape_deck
[ci]: https://github.com/fnordfish/tape_deck/actions/workflows/main.yml
[docs]: https://fnordfish.github.io/tape_deck/docs/latest/
