# New rows and ids

When a test creates rows, the database gives them ids, usually by counting up. Those ids differ from run to run, so a tape that stored them would fail for no real reason. This chapter explains what TapeDeck stores instead, and the settings that tune it.

## Why ids change between runs

The database's counter moves with every insert, also with inserts a test made inside a transaction that was rolled back afterwards. So the id a test gets depends on which tests ran before it, and in which order. With RSpec's random test order, it can be different on every run.

## Placeholders instead of ids

TapeDeck numbers the new rows of each table, and stores a placeholder instead of the id:

```yaml
diff:
  shop:
    orders:
      inserted:
      - id: new shop.orders 1
        status: new
    items:
      inserted:
      - id: new shop.items 1
        order_id: new shop.orders 1
        sku: book
      - id: new shop.items 2
        order_id: new shop.orders 1
        sku: pen
```

`new shop.orders 1` means "the first row this test created in `shop.orders`". The items point at their order with the same placeholder, so the tape still shows which item belongs to which order.

That works for:

- **primary keys the database counts up** (auto increment, `serial`, identity columns), when they're the table's only primary key column
- **foreign keys declared in the database** that point at a new row. They get the placeholder of that row, in new rows and in changed values, like a customer whose `last_order_id` now points at the new order.

Ids of rows that existed before the test stay as they are. They come from your test data, which is the same on every run.

Keys your application sets, like a product code `"A-1"`, stay as they are too. A changed code is a real change.

## Creation order matters, by default

Rows are numbered in the order they were created. If a test creates the same rows in a different order, the numbers end up on different rows, and the tape fails.

That's on purpose: sometimes the order is behavior. A CSV import that must keep the file's order should fail when it suddenly imports the rows sorted by name.

## When order doesn't matter: `number_by_content`

If the order doesn't matter, for example an import whose order is up to the database, or work done in parallel, number those tables by content instead:

```ruby
c.number_by_content "shop.imported_products", "shop.imported_prices"
```

Rows are then sorted by their values (everything except the generated id), and numbered in that order. The same rows get the same numbers, whatever order they were created in.

A row's references count as part of its content, so tables are numbered after the tables they point at. Rows with identical content are numbered in creation order.

## References TapeDeck can't see: `references_to`

TapeDeck finds references through the foreign keys declared in the database. It can't know about:

- references between databases, like `billing.invoices.order_id` pointing at `shop.orders`
- columns that hold another row's id without a declared foreign key

Name them, together with the table they point at:

```ruby
c.references_to "shop.orders", "billing.invoices.order_id", "*.last_order_id"
```

The first value is the table, the others are patterns for the columns that hold its ids. Without this, such a column stores the real id, which changes between runs.

## Other generated keys: `generated_keys`

TapeDeck only knows about keys the database counts up. Keys that are generated differently, like UUIDs, need to be named:

```ruby
c.generated_keys "shop.tokens.id", "*.uuid"
```

The patterns name primary key columns. A UUID tells nothing about when a row was created, so these tables are always numbered by content.

## Keeping real ids: `keep_new_ids`

To store the real ids of some tables after all:

```ruby
c.keep_new_ids "shop.audit_log"
```

Only do that if the ids are the same on every run, for example because the table is emptied and its counter reset before each test.

## The rules are part of the tape

Each tape stores the numbering rules it was recorded with, and is always verified with those. Changing the rules in your configuration only affects tapes recorded afterwards. To apply new rules to an existing tape, record it again.

## Limits

- Ids inside texts or JSON, like `"Order 42"` or `{"order_id": 42}`, are not replaced.
- The rows that exist before the test still need to be the same on every run. Only where the counters stand doesn't matter anymore.

---

Previous: [Choosing what is compared](what-is-compared.md) | Next: [When a tape fails](when-a-tape-fails.md) | [All chapters](index.md)
