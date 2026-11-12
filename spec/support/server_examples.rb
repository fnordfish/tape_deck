# frozen_string_literal: true

# Specs every database server runs. The including group defines +server_url+, a URL without a database, and
# +create_database(server, name)+.
RSpec.shared_examples "a database server" do
  # Configured database name -> database on the server
  def database_names = {"shop" => "tape_deck_shop", "billing" => "tape_deck_billing"}

  before(:all) do
    @server = Sequel.connect(server_url)
    @dbs = database_names.to_h do |name, database|
      create_database(@server, database)
      [name, Sequel.connect("#{server_url}/#{database}")]
    end
  end

  after(:all) do
    next unless @server

    @dbs.each_value(&:disconnect)
    database_names.each_value { @server.run("DROP DATABASE IF EXISTS #{_1}") }
    @server.disconnect
  end

  let(:dbs) { @dbs }
  let(:shop) { dbs.fetch("shop") }
  let(:billing) { dbs.fetch("billing") }

  before do
    reset_databases
    TapeDeck.configure { |c| c.databases = dbs }
  end

  # Recreates all tables, so auto increment ids and rows are the same on every run.
  def reset_databases
    dbs.each_value do |db|
      db.views.each { db.drop_view(_1) }
      # Tables with foreign keys first, so nothing references a dropped table
      db.tables.sort_by { db.foreign_key_list(_1).empty? ? 1 : 0 }.each { db.drop_table(_1) }
    end
    shop.create_table(:orders) do
      primary_key :id
      String :status
      String :note
    end
    shop.create_table(:tags) do
      String :name
    end
    billing.create_table(:invoices) do
      primary_key :id
      Integer :order_id
    end
    shop[:orders].insert(status: "new", note: "a")
    shop[:tags].insert(name: "x")
  end

  def checkout(status: "new")
    id = shop[:orders].insert(status: status, note: "n")
    billing[:invoices].insert(order_id: id)
    shop[:orders].where(id: 1).update(status: "paid")
    shop[:tags].where(name: "x").delete
  end

  def tape_file(name) = File.join(TapeDeck.configuration.tape_library_dir, "#{name}.yml")

  describe "snapshots" do
    let(:recorder) { TapeDeck::Recorder.new(dbs) }

    it "have a checksum for every table" do
      snapshot = recorder.snapshot

      expect(snapshot.transform_values(&:keys)).to eq("shop" => %w[orders tags], "billing" => %w[invoices])
      expect(snapshot.values.flat_map(&:values).map(&:checksum)).to all(satisfy { !_1.nil? })
    end

    it "reuse unchanged tables" do
      before = recorder.snapshot
      shop[:orders].where(id: 1).update(status: "paid")
      after = recorder.snapshot(previous: before)

      expect(after.dig("shop", "tags")).to equal(before.dig("shop", "tags"))
      expect(after.dig("billing", "invoices")).to equal(before.dig("billing", "invoices"))
      expect(after.dig("shop", "orders")).not_to equal(before.dig("shop", "orders"))
    end

    it "skip excluded tables" do
      recorder = TapeDeck::Recorder.new(dbs, exclude_tables: ["shop.tags"])

      expect(recorder.snapshot["shop"].keys).to eq(%w[orders])
    end

    it "leave out views" do
      shop.create_view(:new_orders, shop[:orders].where(status: "new"))

      expect(recorder.snapshot["shop"].keys).to eq(%w[orders tags])
    end

    it "hold included views as a multiset of rows" do
      shop.create_view(:new_orders, shop[:orders].where(status: "new"))
      recorder = TapeDeck::Recorder.new(dbs, include_views: ["shop.new_*"])

      diff = recorder.record { shop[:orders].insert(status: "new", note: "b") }

      expect(diff.dig("shop", "new_orders")).to eq("inserted" => [{"id" => 2, "status" => "new", "note" => "b"}])
      expect(recorder.resolve.dig("shop", "views")).to eq(%w[new_orders])
    end
  end

  describe "new rows" do
    def create_items
      shop.create_table(:items) do
        primary_key :id
        foreign_key :order_id, :orders
        String :sku
      end
    end

    def order_with_items
      order_id = shop[:orders].insert(status: "new")
      %w[a b].each { shop[:items].insert(order_id: order_id, sku: _1) }
    end

    before { create_items }

    it "are numbered, and so are their declared references" do
      TapeDeck.use_tape("order") { order_with_items }

      expect(YAML.safe_load_file(tape_file("order")).dig("diff", "shop", "items", "inserted")).to eq([
        {"id" => "new shop.items 1", "order_id" => "new shop.orders 1", "sku" => "a"},
        {"id" => "new shop.items 2", "order_id" => "new shop.orders 1", "sku" => "b"}
      ])
    end

    it "verify wherever the counters stand" do
      TapeDeck.use_tape("order") { order_with_items }
      reset_databases
      create_items
      3.times { order_with_items }
      shop[:items].delete
      shop[:orders].exclude(id: 1).delete

      expect { TapeDeck.use_tape("order") { order_with_items } }.not_to raise_error
    end
  end

  describe ".use_tape" do
    it "records changes across databases" do
      TapeDeck.use_tape("checkout") { checkout }

      expect(YAML.safe_load_file(tape_file("checkout")).fetch("diff")).to eq(
        "billing" => {"invoices" => {"inserted" => [{"id" => "new billing.invoices 1", "order_id" => 2}]}},
        "shop" => {
          "orders" => {
            "inserted" => [{"id" => "new shop.orders 1", "status" => "new", "note" => "n"}],
            "updated" => [{"key" => {"id" => 1}, "changes" => {"status" => %w[new paid]}}]
          },
          "tags" => {"deleted" => [{"name" => "x"}]}
        }
      )
    end

    it "verifies against the tape" do
      TapeDeck.use_tape("checkout") { checkout }
      reset_databases

      expect { TapeDeck.use_tape("checkout") { checkout } }.not_to raise_error
    end

    it "raises when the changes differ" do
      TapeDeck.use_tape("checkout") { checkout }
      reset_databases

      expect { TapeDeck.use_tape("checkout") { checkout(status: "other") } }
        .to raise_error(TapeDeck::UnexpectedDiffError)
    end
  end
end
