# Writing tests

A tape goes around an action: TapeDeck takes a snapshot of the databases before it, another one after it, and compares the difference with the tape. This chapter shows the ways to put a tape around an action, with RSpec tags and without.

## Tagging RSpec examples

After `c.configure_rspec_metadata!` (see [Configuration](configuration.md)), add `:tape_deck` to an example:

```ruby
RSpec.describe "Checkout" do
  it "creates an order", :tape_deck do
    client.post("/checkout", product: "book")
  end
end
```

Options go in a `tape_deck:` mapping instead:

```ruby
it "creates an order", tape_deck: {databases: ["shop"], only: "shop.orders"} do
  client.post("/checkout", product: "book")
end
```

| Option | Effect |
| --- | --- |
| `record:` | the record mode for this tape: `:once`, `:verify` or `:overwrite`, see [Configuration](configuration.md) |
| `databases:` | watch only these databases, like `["shop"]`. By default, all configured databases. |
| `only:` | compare only what these patterns match, see [Choosing what is compared](what-is-compared.md) |
| `ignore:` | don't compare what these patterns match |
| `tape_name:` | name the tape differently, see "Tape names" below |

## What a tag records

It depends on where the tag is:

| Tag on | Records |
| --- | --- |
| an example (`it`) | One tape around the whole example: its `before(:each)` hooks and `let!`, the example itself, and its `after(:each)` hooks. `before(:all)` runs before the tape starts. |
| a group (`describe` or `context`) | One tape per example inside the group, each as if the example were tagged itself. A group never shares one tape between its examples. |
| no tag, `TapeDeck.use_tape("name") { ... }` inside an example | Only what happens inside the block. If the example is tagged too, its tape contains the block's changes as well. |

A failing example neither records nor verifies its tape, so a broken test can't overwrite a good tape.

To leave one example in a tagged group without a tape, set `tape_deck: false`:

```ruby
RSpec.describe "Checkout", :tape_deck do
  it "creates an order" do ... end                    # gets a tape
  it "shows the cart", tape_deck: false do ... end    # doesn't
end
```

## Tape names

A tape is named after the descriptions of the example and its groups, joined with `/`. `tape_name:` renames the level it's set on. A name starting with `/` replaces the whole name up to that level:

```ruby
describe "A" do                                                 # A
  context "b", tape_deck: {tape_name: "FOO"} do                 # A/FOO
    context "c" do                                              # A/FOO/c
      it "bar", :tape_deck do ... end                           # A/FOO/c/bar.yml
      it "baz", tape_deck: {tape_name: "qux"} do ... end        # A/FOO/c/qux.yml
      it "all", tape_deck: {tape_name: "/orders/all"} do ... end # orders/all.yml
    end
  end
end
```

Every example needs its own tape. Before the first example runs, TapeDeck stops the test run if two tagged examples would share one. That easily happens in a loop:

```ruby
["paid", "shipped"].each do |status|
  it "creates an order", :tape_deck do ... end               # both would be "Checkout/creates an order"
  it "creates an order (#{status})", :tape_deck do ... end   # each gets its own tape
end
```

`#{status}` puts the value of `status` into the text, so the two examples are named "creates an order (paid)" and "creates an order (shipped)".

## Options on groups

Options set on a group apply to all examples in it. When a group inside it, or an example, sets the same option again, the inner one wins. Options it doesn't set are kept:

```ruby
describe "Checkout", tape_deck: {databases: ["shop"], only: "shop.orders"} do
  context "paying", tape_deck: {ignore: "shop.orders.note"} do
    it "by card", tape_deck: {only: "shop.payments", record: :overwrite} do ... end
    it "by invoice" do ... end
  end
end
```

The examples end up with these options:

| Example | `databases` | `only` | `ignore` | `record` |
| --- | --- | --- | --- | --- |
| by card | `["shop"]` | `"shop.payments"` | `"shop.orders.note"` | `:overwrite` |
| by invoice | `["shop"]` | `"shop.orders"` | `"shop.orders.note"` | the configured default |

An option that is a list is replaced as a whole, not extended. If a group ignores `"shop.a"` and an example should ignore `"shop.b"` too, the example lists both: `ignore: ["shop.a", "shop.b"]`.

`tape_name:` is the one option that isn't passed on, it only renames its own level.

## Cleaning up after tests

A tag records the whole example, including its `after(:each)` hooks. If such a hook deletes the rows the test created, that deletion is recorded too, and the tape may end up showing nothing but deleted rows. Three ways around it:

- **Clean up before, not after:** reset the data in `before(:each)` hooks. The changes then happen before the action, and the tape starts from a known state.
- **Roll back outside the tape:** if your suite wraps each test in a database transaction and rolls it back, do that in an `around` hook that is set up before `c.configure_rspec_metadata!`. The rollback then happens after TapeDeck took its last snapshot.
- **Record only the action:** use `use_tape` inside the example, see below.

## Tapes without tags: `use_tape`

`TapeDeck.use_tape` puts a tape around a block of code. It works in any test framework, and in plain scripts:

```ruby
it "creates an order" do
  prepare_cart

  TapeDeck.use_tape("checkout/creates_order") do
    client.post("/checkout", product: "book")
  end

  expect(page).to have_content("Thank you")
end
```

Only the `client.post` is recorded, not `prepare_cart`. The options are the same as for tags, for example `TapeDeck.use_tape("checkout/creates_order", databases: ["shop"]) do ... end`. The name is the complete tape name.

If the block raises an error, the tape is neither recorded nor verified, and the error goes on as usual.

Tapes can be nested. The outer tape then contains everything, including the changes of the inner one:

```ruby
TapeDeck.use_tape("checkout") do                 # records both requests
  client.post("/cart", product: "book")
  TapeDeck.use_tape("checkout/payment") do       # records only this one
    client.post("/pay", card: "4242")
  end
end
```

## Your own RSpec hook

For full control over which examples get a tape, how it's named and which options it uses, write your own hook. Use `insert_tape` and `eject_tape` there:

```ruby
RSpec.configure do |config|
  config.around(:each, :checkout_tape) do |example|
    TapeDeck.insert_tape("checkout/#{example.description}", databases: ["shop"], only: "shop.orders")
    example.run
    # example.run doesn't raise an error when the example fails, so tell TapeDeck to throw the tape away
    TapeDeck.eject_tape(discard: !example.exception.nil?)
  end
end
```

Examples tagged `:checkout_tape` then get a tape named after their description, in a `checkout` directory.

Don't use `TapeDeck.use_tape("...") { example.run }` in a hook: a failing example doesn't raise an error out of `example.run`, so `use_tape` would record or verify the failed example as if it had passed.

`insert_tape` and `eject_tape` work like opening and closing a file by hand: you're responsible for closing. If the action fails, eject with `discard: true`. If ejecting an inner tape raises an error, that tape is ejected anyway, but outer tapes stay inserted, eject them too.

## Turning TapeDeck off

`TapeDeck.turn_off!` turns every tape off: tagged examples just run, and `use_tape` only runs its block. See [Configuration](configuration.md).
