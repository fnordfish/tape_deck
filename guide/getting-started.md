# Getting started

This chapter sets TapeDeck up in an RSpec test suite, records a first tape, and shows what happens when the tested project changes. It takes about ten minutes.

## What you need

- Ruby 3.2 or newer
- A test suite that connects to your databases with [Sequel](https://sequel.jeremyevans.net). TapeDeck works with MySQL, MariaDB, PostgreSQL and SQLite.
- RSpec 3 or 4, for the setup shown here. Other test frameworks work too, see [Writing tests](writing-tests.md).

## 1. Install the gem

Add TapeDeck to the `Gemfile` of your test suite:

```ruby
gem "tape_deck", group: :test
```

Then run:

```console
bundle install
```

## 2. Configure it

Create the file `spec/support/tape_deck.rb`:

```ruby
require "tape_deck"

TapeDeck.configure do |c|
  # Where tapes are stored. This makes the path independent of where you start rspec.
  c.tape_library_dir = File.expand_path("../db_tapes", __dir__)

  # The databases to watch. The names on the left are yours to choose, they appear in tapes and patterns.
  c.databases = {"shop" => SHOP_DB, "billing" => BILLING_DB}

  # Columns that change on every run, so they are never recorded
  c.exclude_columns "*.created_at", "*.updated_at"

  # Lets you tag RSpec examples with :tape_deck
  c.configure_rspec_metadata!
end
```

Replace `SHOP_DB` and `BILLING_DB` with your own database connections. If your suite connects to its databases later, for example in a `before(:suite)` hook, see [Configuration](configuration.md) for how to set them there.

Then load the file from `spec/spec_helper.rb`:

```ruby
require_relative "support/tape_deck"
```

## 3. Tag an example

Pick a test that changes your databases, and add `:tape_deck`:

```ruby
RSpec.describe "Checkout" do
  it "creates an order", :tape_deck do
    client.post("/checkout", product: "book")
  end
end
```

## 4. Run it: the first run records

```console
bundle exec rspec spec/checkout_spec.rb
```

There is no tape yet, so TapeDeck records one: `spec/db_tapes/Checkout/creates_an_order.yml`. Its name comes from the descriptions in your spec, "Checkout" and "creates an order". Open it:

```yaml
---
tape_deck:
  version: 0.1.0
  exclude_columns: ["*.created_at", "*.updated_at"]
  databases:
    shop:
      excluded: [orders.created_at, orders.updated_at]
    billing:
diff:
  billing:
    invoices:
      inserted:
      - id: new billing.invoices 1
        customer_id: 7
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

The `diff` part is what the test changed:

- `inserted`: new rows. The order got an id from the database, but the tape says `new shop.orders 1` instead, the first new row in `shop.orders`. Ids depend on where the database's counter stands, so they would differ on the next run. [New rows and ids](new-rows.md) explains this.
- `updated`: changed rows. The row with `id: 3` in `stock` changed its `quantity` from 10 to 9.
- `deleted`: removed rows, if there were any

The `tape_deck` part is how the tape was made: the TapeDeck version, your rules, and what they left out. TapeDeck needs it to check the tape correctly later.

## 5. Run it again: now it verifies

Run the same test again. This time the tape exists, so TapeDeck compares: the test must change the databases the same way. If it does, the test passes.

Add the tape to version control, like your specs. From now on it describes what this action is supposed to do.

## 6. When something changes

Say the tested project changes, and a checkout now sets the status `"pending"` instead of `"new"`. The test fails, showing what differs:

```
TapeDeck::UnexpectedDiffError:
  DB diff does not match tape spec/db_tapes/Checkout/creates_an_order.yml

  @@ -3,5 +3,5 @@
     orders:
       inserted:
       - id: new shop.orders 1
  -      status: new
  +      status: pending
```

Lines starting with `-` are what the tape expects, lines starting with `+` what happened now. Then it's your call:

- **It's a bug** in the tested project: fix it there, the tape stays as it is.
- **It's an intended change:** record the tape again. Delete the tape file and run the test, or see [When a tape fails](when-a-tape-fails.md) for other ways.

## 7. In CI: verify only

Locally, a missing tape is simply recorded. In CI, a missing tape usually means someone forgot to commit it, so it should fail instead. Add this to the configuration:

```ruby
c.default_record_mode = :verify if ENV["CI"]
```

## Next steps

- [Configuration](configuration.md) lists every setting.
- [Writing tests](writing-tests.md) shows tags on groups, custom tape names, and tapes without RSpec.
- [Choosing what is compared](what-is-compared.md) helps when tapes fail because of values that change on every run.

---

Previous: [TapeDeck guide](index.md) | Next: [Configuration](configuration.md)
