# TapeDeck guide

TapeDeck records what an action changes in your databases, and checks later runs against that recording. This guide explains how to use it, step by step. You don't need to be fluent in Ruby to follow it.

## Chapters

1. [Getting started](getting-started.md): set TapeDeck up, record your first tape, and understand what's in it
2. [Configuration](configuration.md): every setting, what it does, its default, and when to use it
3. [Writing tests](writing-tests.md): tag RSpec examples and groups, name tapes, combine options, and use tapes without RSpec
4. [Choosing what is compared](what-is-compared.md): leave out noise like timestamps, and narrow down what a single test checks
5. [New rows and ids](new-rows.md): why tapes store placeholders like `new shop.orders 1` instead of ids, and how to tune that
6. [When a tape fails](when-a-tape-fails.md): read a failure, decide what to do, and look up every error message
7. [Glossary](glossary.md): the words this guide uses

## Watch out for

The examples assume you know RSpec. A few things trip up even people who do, because of how Ruby blocks and RSpec work:

- **Settings need the `c.`.** Without it, Ruby looks for the method in the surrounding code:

  ```ruby
  TapeDeck.configure do |c|
    exclude_columns "*.created_at"     # 💥 undefined method 'exclude_columns' for main
    c.exclude_columns "*.created_at"   # works
  end
  ```

- **Database connections must exist when the configuration runs.** If `SHOP_DB` is defined after the configuration file is loaded, it fails with "uninitialized constant SHOP_DB". Load the configuration later, or set `databases` in a `before(:suite)` hook, see [Configuration](configuration.md).
- **`tape_deck:` options can't use `let`.** RSpec reads them while it loads the spec file, before any example runs:

  ```ruby
  let(:db_name) { "shop" }
  it "creates an order", tape_deck: {databases: [db_name]} do ... end   # 💥 RSpec fails with a WrongScopeError
  it "creates an order", tape_deck: {databases: ["shop"]} do ... end    # works
  ```

Lines marked with 💥 show what not to do, here and in the other chapters.

The [API documentation](https://fnordfish.github.io/tape_deck/docs/latest/TapeDeck.html) lists every method and option. This guide covers the same ground with more explanation.

---

Next: [Getting started](getting-started.md)
