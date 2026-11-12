# frozen_string_literal: true

RSpec.describe TapeDeck do
  let(:shop) { sqlite_db }
  let(:billing) { sqlite_db }

  before do
    shop.create_table(:orders) do
      primary_key :id
      String :status
      String :note
    end
    billing.create_table(:invoices) do
      primary_key :id
      Integer :order_id
    end

    described_class.configure do |c|
      c.databases = {"shop" => shop, "billing" => billing}
    end
  end

  def checkout(status: "new", note: "n")
    id = shop[:orders].insert(status: status, note: note)
    billing[:invoices].insert(order_id: id)
    id
  end

  def tape_file(name) = File.join(described_class.configuration.tape_library_dir, "#{name}.yml")

  def tape_diff(name) = YAML.safe_load_file(tape_file(name)).fetch("diff")

  def reset_databases
    reset_tables(shop, :orders)
    reset_tables(billing, :invoices)
  end

  it "has a version number" do
    expect(TapeDeck::VERSION).not_to be nil
  end

  describe ".use_tape" do
    it "records a missing tape and returns the block's value" do
      result = described_class.use_tape("checkout") { checkout }

      expect(result).to eq(1)
      expect(File.read(tape_file("checkout"))).to eq(<<~YAML)
        ---
        recorded:
          databases:
            shop:
            billing:
        diff:
          billing:
            invoices:
              inserted:
              - id: new billing.invoices 1
                order_id: 1
          shop:
            orders:
              inserted:
              - id: new shop.orders 1
                status: new
                note: "n"
      YAML
    end

    it "verifies an existing tape" do
      described_class.use_tape("checkout") { checkout }
      reset_databases

      expect { described_class.use_tape("checkout") { checkout } }.not_to raise_error
    end

    it "raises when the diff does not match the tape" do
      described_class.use_tape("checkout") { checkout }
      reset_databases

      expect { described_class.use_tape("checkout") { checkout(status: "paid") } }
        .to raise_error(TapeDeck::UnexpectedDiffError, /does not match tape .*checkout\.yml/) { |error|
          expect(error.expected.dig("shop", "orders", "inserted", 0, "status")).to eq("new")
          expect(error.actual.dig("shop", "orders", "inserted", 0, "status")).to eq("paid")
        }
    end

    it "raises for a missing tape under record mode :verify, without running the block" do
      ran = false

      expect { described_class.use_tape("checkout", record: :verify) { ran = true } }
        .to raise_error(TapeDeck::TapeLoadingError)
      expect(ran).to be(false)
    end

    it "raises when the tape cannot be read" do
      described_class.use_tape("checkout") { checkout }
      File.write(tape_file("checkout"), "shop: [")
      ran = false

      expect { described_class.use_tape("checkout") { ran = true } }.to raise_error(TapeDeck::TapeLoadingError)
      expect(ran).to be(false)
      expect(described_class.current_tape).to be_nil
    end

    it "ignores the order of rows on the tape" do
      shop.create_table(:tags) { String :name }
      described_class.use_tape("tags") { %w[c a b].each { shop[:tags].insert(name: _1) } }
      content = YAML.safe_load_file(tape_file("tags"))
      content.dig("diff", "shop", "tags", "inserted").reverse!
      File.write(tape_file("tags"), TapeDeck::Tape.dump(content))
      reset_tables(shop, :tags)

      expect { described_class.use_tape("tags") { %w[b c a].each { shop[:tags].insert(name: _1) } } }.not_to raise_error
    end

    it "overwrites a tape under record mode :overwrite" do
      described_class.use_tape("checkout") { checkout }
      reset_databases
      described_class.use_tape("checkout", record: :overwrite) { checkout(status: "paid") }

      expect(tape_diff("checkout").dig("shop", "orders", "inserted", 0, "status")).to eq("paid")
    end

    it "discards the tape when the block raises" do
      expect { described_class.use_tape("checkout") { checkout && raise("boom") } }.to raise_error("boom")

      expect(File.exist?(tape_file("checkout"))).to be(false)
      expect(described_class.current_tape).to be_nil
    end

    it "compares only what only: and ignore: leave" do
      described_class.use_tape("checkout") { checkout }
      reset_databases

      expect { described_class.use_tape("checkout", only: "shop.orders.status") { checkout(note: "other") } }
        .not_to raise_error
      reset_databases
      expect { described_class.use_tape("checkout", ignore: "*.note") { checkout(note: "other") } }
        .not_to raise_error
    end
  end

  describe "selecting databases" do
    it "watches only the selected databases and does not query the others" do
      expect(billing).not_to receive(:tables)

      described_class.use_tape("checkout", databases: "shop") { checkout }

      expect(YAML.safe_load_file(tape_file("checkout")).dig("recorded", "databases").keys).to eq(["shop"])
    end

    it "verifies a subset of the recorded databases" do
      described_class.use_tape("checkout") { checkout }
      reset_databases

      expect {
        described_class.use_tape("checkout", databases: "shop") do
          checkout
          billing[:invoices].insert(order_id: 99)
        end
      }.not_to raise_error
    end

    it "verifies the recorded databases when none are selected" do
      described_class.use_tape("checkout", databases: "shop") { checkout }
      reset_databases

      expect(billing).not_to receive(:tables)
      expect { described_class.use_tape("checkout") { checkout } }.not_to raise_error
    end

    it "rejects databases the tape has no recording of, without running the block" do
      described_class.use_tape("checkout", databases: "shop") { checkout }
      ran = false

      expect { described_class.use_tape("checkout", databases: %w[shop billing]) { ran = true } }
        .to raise_error(TapeDeck::IncompatibleTapeError, /no recording of \["billing"\]/)
      expect(ran).to be(false)
    end

    it "rejects unknown databases" do
      expect { described_class.use_tape("checkout", databases: %w[shop mailer]) {} }
        .to raise_error(ArgumentError, /unknown databases \["mailer"\]/)
    end
  end

  describe "excluding" do
    def exclude_note = described_class.configuration.exclude_columns("*.note")

    it "records what was left out" do
      exclude_note
      described_class.configuration.exclude_tables("billing.*")
      described_class.use_tape("checkout") { checkout }

      expect(YAML.safe_load_file(tape_file("checkout")).fetch("recorded")).to eq(
        "exclude_tables" => ["billing.*"],
        "exclude_columns" => ["*.note"],
        "databases" => {"shop" => {"excluded" => ["orders.note"]}, "billing" => {"excluded" => ["invoices"]}}
      )
    end

    it "verifies a tape that holds data excluded now" do
      described_class.use_tape("checkout") { checkout }
      reset_databases
      exclude_note
      described_class.configuration.exclude_tables("billing.invoices")

      expect {
        described_class.use_tape("checkout") do
          checkout(note: "other")
          billing[:invoices].insert(order_id: 99)
        end
      }.not_to raise_error
    end

    it "rejects a tape that lacks data that is no longer excluded" do
      exclude_note
      described_class.use_tape("checkout") { checkout }
      reset_databases
      described_class.configuration.excluded_columns.clear

      expect { described_class.use_tape("checkout") { checkout } }
        .to raise_error(TapeDeck::IncompatibleTapeError, /left out \["orders.note"\] of shop/)
    end
  end

  describe "schema changes" do
    before do
      described_class.configuration.exclude_columns("*.note")
      described_class.use_tape("checkout") { checkout }
      reset_databases
      billing.alter_table(:invoices) { add_column :note, String }
    end

    it "raises when the recorded exclude rules match other columns now" do
      expect { described_class.use_tape("checkout") { checkout } }
        .to raise_error(TapeDeck::IncompatibleTapeError, /schema changed.*billing excluded: added \["invoices.note"\], removed \[\]/)
    end

    it "notices excluded columns that are gone" do
      shop.alter_table(:orders) { drop_column :note }

      expect { described_class.use_tape("checkout") { shop[:orders].insert(status: "new") } }
        .to raise_error(TapeDeck::IncompatibleTapeError, /shop excluded: added \[\], removed \["orders.note"\]/)
    end

    it "warns and verifies, if configured" do
      described_class.configuration.on_schema_change = :warn

      expect { described_class.use_tape("checkout") { checkout } }
        .to output(/TapeDeck: schema changed/).to_stderr
    end

    it "verifies silently, if configured" do
      described_class.configuration.on_schema_change = :ignore

      expect { described_class.use_tape("checkout") { checkout } }.not_to output.to_stderr
    end
  end

  describe "views" do
    def create_statuses_view(count: Sequel.function(:count).*)
      shop.create_view(:order_statuses, shop[:orders].select(:status, Sequel.as(count, :count)).group(:status))
    end

    def include_statuses = described_class.configuration.include_views("shop.order_*")

    def recorded = YAML.safe_load_file(tape_file("checkout")).fetch("recorded")

    before { create_statuses_view }

    it "leaves views out by default" do
      described_class.use_tape("checkout") { checkout }

      expect(tape_diff("checkout")["shop"].keys).to eq(["orders"])
      expect(recorded.dig("databases", "shop")).to be_nil
    end

    it "records included views as a multiset of rows" do
      include_statuses
      described_class.use_tape("checkout") { checkout }
      described_class.use_tape("checkout/again") { checkout }

      expect(tape_diff("checkout").dig("shop", "order_statuses")).to eq("inserted" => [{"status" => "new", "count" => 1}])
      expect(tape_diff("checkout/again").dig("shop", "order_statuses")).to eq(
        "inserted" => [{"status" => "new", "count" => 2}],
        "deleted" => [{"status" => "new", "count" => 1}]
      )
      expect(recorded).to include("include_views" => ["shop.order_*"])
      expect(recorded.dig("databases", "shop")).to eq("views" => ["order_statuses"])
    end

    it "notices a changed view definition" do
      include_statuses
      described_class.use_tape("checkout") { checkout }
      reset_databases
      shop.drop_view(:order_statuses)
      create_statuses_view(count: Sequel.function(:count).* * 2)

      expect { described_class.use_tape("checkout") { checkout } }.to raise_error(TapeDeck::UnexpectedDiffError)
    end

    it "excludes view columns" do
      include_statuses
      described_class.configuration.exclude_columns("*.count")
      described_class.use_tape("checkout") { checkout }

      expect(tape_diff("checkout").dig("shop", "order_statuses")).to eq("inserted" => [{"status" => "new"}])
      expect(recorded.dig("databases", "shop", "excluded")).to eq(["order_statuses.count"])
    end

    it "verifies a tape with a view that is no longer included" do
      include_statuses
      described_class.use_tape("checkout") { checkout }
      reset_databases
      described_class.configuration.included_views.clear

      expect { described_class.use_tape("checkout") { checkout } }.not_to raise_error
    end

    it "rejects a tape that lacks a view that is included now" do
      described_class.use_tape("checkout") { checkout }
      reset_databases
      include_statuses

      expect { described_class.use_tape("checkout") { checkout } }
        .to raise_error(TapeDeck::IncompatibleTapeError, /no recording of the views \["order_statuses"\] of shop/)
    end

    describe "added by a schema change" do
      before do
        include_statuses
        described_class.use_tape("checkout") { checkout }
        reset_databases
        shop.create_view(:order_notes, shop[:orders].select(:note))
      end

      it "raises" do
        expect { described_class.use_tape("checkout") { checkout } }
          .to raise_error(TapeDeck::IncompatibleTapeError, /shop views: added \["order_notes"\], removed \[\]/)
      end

      it "warns and verifies without the new view, if configured" do
        described_class.configuration.on_schema_change = :warn

        expect { described_class.use_tape("checkout") { checkout } }.to output(/shop views: added/).to_stderr
      end
    end
  end

  describe "new rows" do
    before do
      shop.create_table(:items) do
        primary_key :id
        foreign_key :order_id, :orders
        String :sku
      end
      shop.create_table(:customers) do
        primary_key :id
        foreign_key :last_order_id, :orders
      end
      shop.create_table(:skus) do
        String :code, primary_key: true
      end
      shop[:customers].insert(id: 1)
    end

    def order_with_items(*skus, status: "new")
      order_id = shop[:orders].insert(status: status)
      skus.each { shop[:items].insert(order_id: order_id, sku: _1) }
      order_id
    end

    # SQLite keeps counting after rows are deleted, like MySQL and PostgreSQL after a rollback
    def move_counters
      2.times { order_with_items("x") }
      shop[:items].delete
      shop[:orders].delete
    end

    it "replaces new ids and declared references with placeholders" do
      described_class.use_tape("order") { order_with_items("a", "b") }

      expect(tape_diff("order").fetch("shop")).to eq(
        "orders" => {"inserted" => [{"id" => "new shop.orders 1", "status" => "new", "note" => nil}]},
        "items" => {
          "inserted" => [
            {"id" => "new shop.items 1", "order_id" => "new shop.orders 1", "sku" => "a"},
            {"id" => "new shop.items 2", "order_id" => "new shop.orders 1", "sku" => "b"}
          ]
        }
      )
    end

    it "verifies, wherever the counters stand" do
      described_class.use_tape("order") { order_with_items("a", "b") }
      move_counters

      expect { described_class.use_tape("order") { order_with_items("a", "b") } }.not_to raise_error
    end

    it "numbers rows in creation order, so a different order is noticed" do
      described_class.use_tape("orders") { order_with_items(status: "a") && order_with_items(status: "b") }
      move_counters

      expect { described_class.use_tape("orders") { order_with_items(status: "b") && order_with_items(status: "a") } }
        .to raise_error(TapeDeck::UnexpectedDiffError)
    end

    it "replaces references to new rows in updated values" do
      described_class.use_tape("customer") do
        shop[:customers].where(id: 1).update(last_order_id: order_with_items)
      end

      expect(tape_diff("customer").dig("shop", "customers", "updated")).to eq(
        [{"key" => {"id" => 1}, "changes" => {"last_order_id" => [nil, "new shop.orders 1"]}}]
      )
    end

    it "keeps ids of rows that existed before" do
      existing = shop[:orders].insert(status: "old")
      described_class.use_tape("item") { shop[:items].insert(order_id: existing, sku: "a") }

      expect(tape_diff("item").dig("shop", "items", "inserted")).to eq(
        [{"id" => "new shop.items 1", "order_id" => existing, "sku" => "a"}]
      )
    end

    it "keeps keys the database does not generate" do
      described_class.use_tape("sku") { shop[:skus].insert(code: "A-1") }

      expect(tape_diff("sku").dig("shop", "skus", "inserted")).to eq([{"code" => "A-1"}])
    end

    describe "numbered by content" do
      before { described_class.configuration.number_by_content("shop.orders", "shop.items") }

      # Items only differ by their order, so they can only be told apart once their orders are numbered
      def import(*statuses) = statuses.each { order_with_items("x", status: _1) }

      it "verifies the same rows created in a different order" do
        described_class.use_tape("import") { import("a", "b", "c") }
        move_counters

        expect { described_class.use_tape("import") { import("c", "a", "b") } }.not_to raise_error
        expect(tape_diff("import").dig("shop", "items", "inserted")).to include(
          {"id" => "new shop.items 2", "order_id" => "new shop.orders 2", "sku" => "x"}
        )
      end

      it "still notices changed rows" do
        described_class.use_tape("import") { import("a", "b") }
        move_counters

        expect { described_class.use_tape("import") { import("a", "x") } }.to raise_error(TapeDeck::UnexpectedDiffError)
      end

      it "numbers rows that reference their own table" do
        shop.create_table(:comments) do
          primary_key :id
          foreign_key :parent_id, :comments
          String :body
        end
        described_class.configuration.number_by_content("shop.comments")
        # Replies only differ by body once their parent ids don't count, which depend on the creation order
        threads = ->(*names) do
          names.each { shop[:comments].insert(body: "re #{_1}", parent_id: shop[:comments].insert(body: _1)) }
        end
        described_class.use_tape("threads") { threads.call("a", "b") }
        shop[:comments].delete

        expect { described_class.use_tape("threads") { threads.call("b", "a") } }.not_to raise_error
        expect(tape_diff("threads").dig("shop", "comments", "inserted")).to include(
          {"id" => "new shop.comments 1", "parent_id" => "new shop.comments 3", "body" => "re a"},
          {"id" => "new shop.comments 3", "parent_id" => nil, "body" => "a"}
        )
      end
    end

    describe "configured" do
      it "replaces references across databases" do
        described_class.configuration.references_to("shop.orders", "billing.invoices.order_id")
        described_class.use_tape("checkout") { checkout }
        move_counters

        expect { described_class.use_tape("checkout") { checkout } }.not_to raise_error
        expect(tape_diff("checkout").dig("billing", "invoices", "inserted")).to eq(
          [{"id" => "new billing.invoices 1", "order_id" => "new shop.orders 1"}]
        )
      end

      it "replaces references without a foreign key, matched by pattern" do
        shop.create_table(:notes) do
          primary_key :id
          Integer :order_ref
        end
        described_class.configuration.references_to("shop.orders", "*.order_ref")
        described_class.use_tape("note") { shop[:notes].insert(order_ref: order_with_items) }

        expect(tape_diff("note").dig("shop", "notes", "inserted", 0)).to include("order_ref" => "new shop.orders 1")
      end

      it "replaces generated keys that are not auto increment, numbered by content" do
        shop.create_table(:tokens) do
          String :id, primary_key: true
          String :value
        end
        shop.create_table(:uses) do
          primary_key :id
          foreign_key :token_id, :tokens, type: String
        end
        described_class.configuration.generated_keys("shop.tokens.id")
        # Issuing tokens in another order creates the uses in another order too
        described_class.configuration.number_by_content("shop.uses")
        issue = ->(*values) do
          values.each do |value|
            token = SecureRandom.uuid
            shop[:tokens].insert(id: token, value: value)
            shop[:uses].insert(token_id: token)
          end
        end
        # Six of them, so random UUIDs can't happen to be in content order (1 in 720)
        values = %w[a b c d e f]
        described_class.use_tape("tokens") { issue.call(*values) }

        expect { described_class.use_tape("tokens") { issue.call(*values.reverse) } }.not_to raise_error
        expect(tape_diff("tokens").dig("shop", "tokens", "inserted")).to match_array(
          values.each_with_index.map { |value, i| {"id" => "new shop.tokens #{i + 1}", "value" => value} }
        )
      end
    end

    it "keeps new ids of tables configured to keep them" do
      described_class.configuration.keep_new_ids("shop.items")
      move_counters
      described_class.use_tape("order") { order_with_items("a") }

      expect(tape_diff("order").dig("shop", "items", "inserted", 0)).to include("id" => 3, "order_id" => "new shop.orders 1")
    end
  end

  describe "nested tapes" do
    it "records the inner changes on both tapes" do
      described_class.use_tape("outer") do
        checkout
        described_class.use_tape("inner", databases: "shop") do
          expect(described_class.current_tape.name).to eq("inner")
          checkout(status: "inner")
        end
        expect(described_class.current_tape.name).to eq("outer")
      end

      expect(tape_diff("outer").dig("shop", "orders", "inserted").size).to eq(2)
      expect(tape_diff("inner").dig("shop", "orders", "inserted").size).to eq(1)
    end

    it "discards the outer tape when the inner one fails to verify" do
      described_class.use_tape("inner") { checkout }
      reset_databases

      expect {
        described_class.use_tape("outer") do
          described_class.use_tape("inner") { checkout(status: "changed") }
        end
      }.to raise_error(TapeDeck::UnexpectedDiffError)
      expect(File.exist?(tape_file("outer"))).to be(false)
      expect(described_class.current_tape).to be_nil
    end
  end

  describe ".insert_tape and .eject_tape" do
    it "record a tape without a block" do
      tape = described_class.insert_tape("manual")
      checkout

      expect(described_class.eject_tape).to equal(tape)
      expect(File.exist?(tape_file("manual"))).to be(true)
    end

    it "eject a tape that fails to verify, but leave outer tapes inserted" do
      described_class.use_tape("inner") { checkout }
      reset_databases
      outer = described_class.insert_tape("outer")
      described_class.insert_tape("inner")
      checkout(status: "changed")

      expect { described_class.eject_tape }.to raise_error(TapeDeck::UnexpectedDiffError)
      expect(described_class.current_tape).to equal(outer)
      expect(described_class.eject_tape(discard: true)).to equal(outer)
      expect(File.exist?(tape_file("outer"))).to be(false)
    end

    it "eject nothing when no tape is inserted" do
      expect(described_class.eject_tape).to be_nil
    end
  end
end
