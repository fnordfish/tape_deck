# Configuration

TapeDeck is configured once, usually in `spec/support/tape_deck.rb`. This chapter shows a complete configuration, then explains every setting.

## A complete example

```ruby
require "tape_deck"

TapeDeck.configure do |c|
  # Where tapes are stored
  c.tape_library_dir = File.expand_path("../db_tapes", __dir__)

  # The databases to watch, by the names used in tapes and patterns
  c.databases = {"shop" => SHOP_DB, "billing" => BILLING_DB}

  # In CI, a missing tape is an error instead of being recorded
  c.default_record_mode = :verify if ENV["CI"]

  # Never record these tables and columns
  c.exclude_tables "shop.sessions", "*.schema_migrations"
  c.exclude_columns "*.created_at", "*.updated_at"

  # Also record these views
  c.include_views "shop.order_totals"

  # How new rows are numbered, see "New rows and ids"
  c.number_by_content "shop.imported_products"
  c.references_to "shop.orders", "billing.invoices.order_id"

  # Lets you tag RSpec examples with :tape_deck
  c.configure_rspec_metadata!
end
```

Only `databases` is required. Everything else has a default that works for most suites.

## All settings at a glance

| Setting | Default | In short |
| --- | --- | --- |
| `tape_library_dir` | `"spec/db_tapes"` | where tape files are stored |
| `databases` | none | the databases to watch, by name |
| `default_record_mode` | `:once` | whether a test records, verifies or both |
| `on_schema_change` | `:error` | what happens when the database schema changed since recording |
| `exclude_tables` | none | tables that are never recorded |
| `exclude_columns` | none | columns that are never recorded |
| `include_views` | none | views that are recorded, views are left out otherwise |
| `keep_new_ids` | none | tables whose new rows keep their real ids |
| `number_by_content` | none | tables whose new rows are numbered by content instead of creation order |
| `references_to` | none | columns that point at rows of another table, beyond declared foreign keys |
| `generated_keys` | none | primary keys that are generated, but not auto increment, like UUIDs |
| `configure_rspec_metadata!` | off | lets you tag RSpec examples with `:tape_deck` |

Settings like `exclude_columns` can be called several times, each call adds to the list.

## Patterns

Many settings take patterns. They name tables, columns and views like this:

- a table or view: `"<database>.<table>"`, like `"shop.orders"`
- a column: `"<database>.<table>.<column>"`, like `"shop.orders.created_at"`

`<database>` is the name you gave the database in `databases`. A `*` stands for any text, including dots, and `{a,b}` for one of several choices:

| Pattern | Matches | Doesn't match |
| --- | --- | --- |
| `"shop.orders"` | the table `shop.orders` | `shop.order_items` |
| `"*.created_at"` | `created_at` in every table of every database | `shop.orders.status` |
| `"shop.*.created_at"` | `created_at` in every table of `shop` | `billing.invoices.created_at` |
| `"shop.*"` | every table and every column in `shop` | anything in `billing` |
| `"shop.order*"` | the tables `shop.orders` and `shop.order_items`, and as a column pattern all their columns | `shop.users` |
| `"*.{orders,invoices}"` | the tables `shop.orders` and `billing.invoices` | `shop.order_items` |

Because `*` also matches dots, a pattern can match more than you might expect. `"shop.order*"` used with `exclude_columns` leaves out every column of `orders` and `order_items`.

## Where tapes are stored: `tape_library_dir`

The directory tape files are written to and read from. A tape named `Checkout/creates an order` becomes the file `Checkout/creates_an_order.yml` in it. Characters other than letters, digits, `-`, `_` and `/` become `_`.

Default: `"spec/db_tapes"`, relative to the directory you start your tests from. To make it independent of that, set it relative to the configuration file:

```ruby
c.tape_library_dir = File.expand_path("../db_tapes", __dir__)
```

## The databases to watch: `databases`

A mapping from a name to a database connection (a `Sequel::Database`):

```ruby
c.databases = {"shop" => SHOP_DB, "billing" => BILLING_DB}
```

The names are yours to choose. They appear in tapes and in all patterns, so pick short, stable ones. Renaming one later means re-recording the tapes that use it.

If your suite only connects to its databases when it starts, set them there. TapeDeck only needs them when the first tape is used:

```ruby
RSpec.configure do |config|
  config.before(:suite) do
    TapeDeck.configuration.databases = {"shop" => SHOP_DB, "billing" => BILLING_DB}
  end
end
```

By default, every tape watches all of these databases. A single test can watch fewer, with the `databases:` option, see [Writing tests](writing-tests.md).

## Recording or verifying: `default_record_mode`

Decides what a test does with its tape:

| Mode | When the tape is missing | When the tape exists |
| --- | --- | --- |
| `:once` (default) | records it | verifies against it |
| `:verify` | fails with `TapeDeck::TapeLoadingError` | verifies against it |
| `:overwrite` | records it | records it again, replacing it |

```ruby
c.default_record_mode = :verify if ENV["CI"]
```

A single test can choose its own mode with the `record:` option, for example `record: :overwrite` while you re-record one tape. See [When a tape fails](when-a-tape-fails.md) for re-recording.

## When the schema changed: `on_schema_change`

A tape remembers which tables and columns your rules left out, and which views they included. If the rules now match other tables, columns or views, for example because a column was added that matches `"*.created_at"`, the database schema changed since the tape was recorded. This setting decides what happens then:

| Value | Effect |
| --- | --- |
| `:error` (default) | the test fails with `TapeDeck::IncompatibleTapeError`, naming what was added or removed |
| `:warn` | a warning is printed, and the tape is verified anyway |
| `:ignore` | the tape is verified, nothing is printed |

```ruby
c.on_schema_change = :warn
```

## Never recorded: `exclude_tables` and `exclude_columns`

For data that changes on every run, or that no test cares about: timestamps, session tables, migration bookkeeping. Excluded data never ends up on a tape.

```ruby
c.exclude_tables "shop.sessions", "*.schema_migrations"
c.exclude_columns "*.created_at", "*.updated_at", "shop.users.last_seen_at"
```

Primary key columns are never excluded, even if a pattern matches them, because TapeDeck needs them to tell rows apart.

To leave something out of a single test only, use `ignore:` or `only:` instead, see [Choosing what is compared](what-is-compared.md).

## Recording views: `include_views`

Views are left out by default: a view holds no data of its own, so the changes of the tables behind it are recorded anyway. Include a view to also notice when its definition changes, or when it shows data from tables you don't record:

```ruby
c.include_views "shop.order_totals", "billing.*"
```

Included views are read completely on every snapshot, which takes more time than reading tables. `exclude_columns` applies to their columns.

## Numbering new rows: `keep_new_ids`, `number_by_content`, `references_to`, `generated_keys`

These four settings control how tapes store the ids of new rows. They have their own chapter, [New rows and ids](new-rows.md).

```ruby
c.keep_new_ids "shop.audit_log"
c.number_by_content "shop.imported_products"
c.references_to "shop.orders", "billing.invoices.order_id", "*.last_order_id"
c.generated_keys "shop.tokens.id"
```

## RSpec tags: `configure_rspec_metadata!`

Lets you put a tape around an RSpec example by tagging it with `:tape_deck`, see [Writing tests](writing-tests.md). Call it once, at the end of the configuration.

## Turning TapeDeck off

To run your tests without TapeDeck, for example because you don't need tapes right now and want to save the time snapshots take:

```ruby
TapeDeck.turn_off! if ENV["TAPE_DECK"] == "off"
```

While it's off, tagged tests just run, and `use_tape` only runs its block. No database is read, and no tape is read, written or verified. `TapeDeck.turn_on!` turns it back on, and `TapeDeck.turned_off { ... }` turns it off while a block runs.

## Changing the configuration later

Each tape stores the rules it was recorded with. That's why some changes need re-recording and others don't:

| You change | Existing tapes |
| --- | --- |
| `tape_library_dir` | are looked for in the new place, move them along |
| a name in `databases` | need re-recording, the old name is on them |
| `default_record_mode`, `on_schema_change` | are not affected |
| `exclude_tables`, `exclude_columns`: exclude more | keep working, what's excluded now is just not compared anymore |
| `exclude_tables`, `exclude_columns`: exclude less | fail with `TapeDeck::IncompatibleTapeError`, they lack that data. Re-record them. |
| `include_views`: include fewer | keep working, the views not included anymore aren't compared |
| `include_views`: include more | fail with `TapeDeck::IncompatibleTapeError`, they lack those views. Re-record them. |
| `keep_new_ids`, `number_by_content`, `references_to`, `generated_keys` | are not affected: a tape is always verified with the numbering rules it was recorded with. New rules apply to tapes recorded afterwards. |
