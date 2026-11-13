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

## Reading the examples

The examples are Ruby, but you only need a few pieces of it:

| You see | It means |
| --- | --- |
| `"shop"` | a text (string) |
| `["shop", "billing"]` | a list of texts |
| `{"shop" => SHOP_DB}` | a mapping, here from the name `"shop"` to a database connection |
| `:once` | a fixed value (symbol), used for settings that have a few allowed values |
| `databases: ["shop"]` | an option named `databases`, set to a list |
| `# text` | a comment, Ruby ignores it |

The configuration is written as a block:

```ruby
TapeDeck.configure do |c|
  c.databases = {"shop" => SHOP_DB}
end
```

TapeDeck hands you its configuration as `c`, and the lines between `do` and `end` set it up.

Names like `SHOP_DB` stand for your own database connections. They're `Sequel::Database` objects, which your test suite most likely creates already.

The API documentation lists every method and option for Ruby developers. This guide covers the same ground with more explanation.
