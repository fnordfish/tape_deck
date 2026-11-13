# When a tape fails

This chapter explains how to read a failing tape, how to decide what to do about it, and lists every error TapeDeck raises, with what it means and how to fix it.

## Reading the difference

When a test changes the databases differently than its tape says, it fails with `TapeDeck::UnexpectedDiffError`:

```
DB diff does not match tape spec/db_tapes/checkout.yml

@@ -3,5 +3,5 @@
   orders:
     inserted:
     - id: new shop.orders 1
-      status: new
+      status: paid
       note: "n"
```

- Lines starting with `-` are on the tape, but didn't happen this time.
- Lines starting with `+` happened this time, but aren't on the tape.
- The other lines are context, to show where the difference is.

Here, the test created an order with the status `paid`, but the tape expects `new`.

## Bug or intended change?

A failing tape means the tested project behaves differently than when the tape was recorded. Decide which it is:

- **A bug:** fix it in the tested project. The tape stays as it is, and passes again once the bug is gone.
- **An intended change:** record the tape again, see below.
- **Noise:** a value that changes on every run, like a timestamp or a token. Exclude or ignore it, see [Choosing what is compared](what-is-compared.md). Ids of new rows are already handled, see [New rows and ids](new-rows.md).

## Recording a tape again

Any of these works:

- **Delete the tape file** and run the test. With the default record mode, a missing tape is recorded.
- **Record one tape again:** set `record: :overwrite` for that test, run it once, and remove the option again:

  ```ruby
  it "creates an order", tape_deck: {record: :overwrite} do ... end
  ```

- **Record all tapes again:** add a switch to your configuration, and set it when you need it:

  ```ruby
  c.default_record_mode = :overwrite if ENV["TAPE_DECK_RECORD"]
  ```

  ```console
  TAPE_DECK_RECORD=1 bundle exec rspec
  ```

  Tests with their own `record:` option keep it.

Check the new tape with `git diff` before committing it. It should only change where you expect.

## Every error, explained

### `TapeDeck::UnexpectedDiffError`

```
DB diff does not match tape spec/db_tapes/checkout.yml
```

The test changed the databases differently than the tape says. See "Reading the difference" above.

### `TapeDeck::TapeLoadingError`

```
no tape at spec/db_tapes/nothing.yml (record mode :verify)
```

The test may only verify (record mode `:verify`, often in CI), but there's no tape. Record it locally and commit it, or check that the tape name and `tape_library_dir` are right.

```
cannot load tape spec/db_tapes/broken.yml: (spec/db_tapes/broken.yml): did not find expected node content while parsing a flow node at line 2 column 1
```

The tape file isn't valid YAML, often after a merge conflict or a manual edit. Fix the file at the line mentioned, or record the tape again.

```
tape spec/db_tapes/old.yml does not hold a recording
```

The file is valid YAML, but not a tape TapeDeck can read. Most likely it was recorded by an older version of TapeDeck with a different file format, the CHANGELOG says when that happened. Record the tape again.

### `TapeDeck::IncompatibleTapeError`

The tape can't be used for this test as it is now. It needs recording again, or the configuration needs to go back to how it was.

```
tape spec/db_tapes/shop_only.yml has no recording of ["billing"], it was recorded with ["shop"]
```

The test asks to watch a database (here `billing`) that the tape didn't watch when it was recorded. Remove it from the test's `databases:` option, or record the tape again.

```
tape spec/db_tapes/excluded.yml left out ["orders.note"] of shop, which is no longer excluded. Re-record the tape.
```

The tape was recorded while `shop.orders.note` was excluded, so it has no data for that column. Now it isn't excluded anymore. Record the tape again, or exclude the column again.

```
tape spec/db_tapes/report.yml has no recording of the views ["order_totals"] of shop, which are included now. Re-record the tape.
```

The same for views: a view is included now that wasn't when the tape was recorded. Record the tape again.

```
schema changed since tape spec/db_tapes/excluded.yml was recorded, its recording rules now match other tables, columns or views (billing excluded: added ["invoices.note"], removed [])
```

The database schema changed since recording: the rules from the tape now match something they didn't before, here a new column `billing.invoices.note` that matches `"*.note"`. Check whether the change is expected, then record the tape again. If schema changes like this are normal in your project, set `c.on_schema_change = :warn` or `:ignore`, see [Configuration](configuration.md).

### `TapeDeck::Error`

```
TapeDeck: examples share a tape. Give each its own description or tape_name:
  Checkout/creates_an_order.yml:
    ./spec/checkout_spec.rb[1:1] "Checkout/creates an order"
    ./spec/checkout_spec.rb[1:2] "Checkout/creates an order"
```

Several tagged examples would use the same tape, often the same description in a loop. Nothing ran yet. Give each example its own description or `tape_name:`, see [Writing tests](writing-tests.md).

```
eject tape "open" before turning TapeDeck off
```

`TapeDeck.turn_off!` was called while a tape is in use. Turn TapeDeck off before the test starts, for example in the configuration.

### `ArgumentError`

```
unknown databases ["mailer"], configured are ["shop", "billing"]
```

A test's `databases:` option names a database that isn't configured. Check the spelling, or add it to `c.databases`.

```
invalid record mode :all, use one of [:once, :verify, :overwrite]
```

```
invalid schema change action :fail, use one of [:error, :warn, :ignore]
```

A setting got a value it doesn't know. The message lists the allowed ones.
