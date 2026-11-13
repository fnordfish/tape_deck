# Glossary

**Action**: the code a tape is put around, like a request to the tested project.

**Tape**: a YAML file that holds what an action changed in the databases, and how it was recorded. Tests are checked against it.

**Tape library**: the directory tapes are stored in, see `tape_library_dir` in [Configuration](configuration.md).

**Tape name**: identifies a tape, and decides its file name. `Checkout/creates an order` is stored as `Checkout/creates_an_order.yml`.

**Snapshot**: what TapeDeck reads from the databases before and after the action, to see what changed.

**Diff**: the difference between the two snapshots, as new (`inserted`), changed (`updated`) and removed (`deleted`) rows.

**Record**: write the diff to the tape, because there is none yet, or because the record mode says so.

**Verify**: compare the diff with the tape. The test fails if they differ.

**Discard**: neither record nor verify, because the action or the test failed.

**Record mode**: decides whether a test records, verifies or both: `:once`, `:verify` or `:overwrite`, see [Configuration](configuration.md).

**Exclude**: never record a table or column, for every tape, see [Choosing what is compared](what-is-compared.md).

**Ignore**: record, but don't compare, for one test. `only:` is the opposite: compare nothing else.

**Pattern**: names tables, columns or views, with `*` for any text, like `"*.created_at"`, see [Configuration](configuration.md).

**Placeholder**: what a tape stores instead of the id of a new row, like `new shop.orders 1`, see [New rows and ids](new-rows.md).

**Generated key**: an id the database (or the application) creates for a new row, like an auto increment number or a UUID.

**Reference**: a column that holds the id of another row, like `order_id`. Declared foreign keys are found automatically.

**Schema change**: tables, columns or views were added or removed since a tape was recorded.

**Insert and eject**: start and end a tape by hand, without a block, see [Writing tests](writing-tests.md).

---

Previous: [When a tape fails](when-a-tape-fails.md) | [All chapters](index.md)
