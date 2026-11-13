# Choosing what is compared

A tape fails when anything it recorded changes. Some values change on every run, like timestamps or tokens, and some tests only care about part of what changed. This chapter shows how to narrow it down.

## I want to...

| I want to... | Use | Where |
| --- | --- | --- |
| never record a table, like sessions | `exclude_tables` | configuration |
| never record a column, like `created_at` | `exclude_columns` | configuration |
| record a view too | `include_views` | configuration |
| not compare something in one test, but keep it on the tape | `ignore:` | one test |
| compare only some tables or columns in one test | `only:` | one test |
| watch only some databases in one test | `databases:` | one test |
| store new rows independent of their ids | nothing, that's automatic | see [New rows and ids](new-rows.md) |

All of these take patterns like `"shop.orders"` or `"*.created_at"`, see [Configuration](configuration.md) for how patterns work.

## Excluding: never recorded

`exclude_tables` and `exclude_columns` are set once, in the configuration, and apply to every tape. Excluded data never reaches a tape:

```ruby
c.exclude_tables "shop.sessions", "*.schema_migrations"
c.exclude_columns "*.created_at", "*.updated_at", "*.token"
```

Use them for noise no test cares about. New, changed and deleted rows are still recorded, just without those columns. A row where only excluded columns changed doesn't show up at all.

Primary key columns are never excluded, because TapeDeck needs them to tell rows apart.

## Ignoring: recorded, but not compared

`ignore:` and `only:` are set per test. The tape still holds everything, they only change what's compared when verifying:

```ruby
# Compare everything except the order notes
it "creates an order", tape_deck: {ignore: "shop.orders.note"} do ... end

# Compare only the order status, nothing else
it "marks the order as paid", tape_deck: {only: "shop.orders.status"} do ... end
```

Both take one pattern or a list, like `ignore: ["shop.orders.note", "billing.*"]`. A pattern can name a whole database (`"billing.*"`), a table (`"shop.orders"`) or a column (`"shop.orders.status"`). With `only:`, everything else is ignored. If `only:` and `ignore:` both match something, `ignore:` wins.

Because the tape holds everything, you can change `ignore:` and `only:` at any time without re-recording.

## Excluding or ignoring?

- **Exclude** what no test should ever compare. It keeps tapes small and readable.
- **Ignore** what one test doesn't care about, but other tests using similar actions might.

Excluding less later means re-recording, because the tapes lack that data. Excluding more is fine, existing tapes just stop comparing it. See the table at the end of [Configuration](configuration.md).

## Watching fewer databases: `databases:`

By default, a tape watches all configured databases. To watch only some of them:

```ruby
it "sends a welcome mail", tape_deck: {databases: ["mailer"]} do ... end
```

The other databases are neither read nor compared, so changes there go unnoticed. That also makes the test faster.

When verifying, a tape watches the databases it was recorded with. `databases:` can narrow that down further, but can't add a database the tape has no recording of.

## Views

Views are not recorded unless you include them with `include_views`, see [Configuration](configuration.md). A view's rows are compared as a whole: a changed row shows up as one deleted and one inserted row.

## Rows without a primary key

Rows are matched by their primary key, so a changed row shows up as `updated`, with the old and new values. Tables without a primary key can't do that. Their rows are compared as a whole, like views: a changed row is one deleted and one inserted row.

## Row order doesn't matter

The order of rows on a tape is only for reading. When verifying, both sides are sorted the same way first, so rows don't need to come out in the same order.

---

Previous: [Writing tests](writing-tests.md) | Next: [New rows and ids](new-rows.md) | [All chapters](index.md)
