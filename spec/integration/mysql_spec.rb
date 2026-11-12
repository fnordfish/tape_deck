# frozen_string_literal: true

# Runs against a real MySQL server. Set TAPE_DECK_MYSQL_URL to a server URL without a database, e.g.
# "mysql2://root:tape_deck@mysql" or "trilogy://root:tape_deck@mysql". See .devcontainer/compose.yml.
RSpec.describe "MySQL", :mysql do
  # Configured database name -> MySQL database
  def database_names = {"shop" => "tape_deck_shop", "billing" => "tape_deck_billing"}

  before(:all) do
    url = ENV.fetch("TAPE_DECK_MYSQL_URL")
    @server = Sequel.connect(url)
    @dbs = database_names.to_h do |name, database|
      @server.run("CREATE DATABASE IF NOT EXISTS #{database}")
      [name, Sequel.connect("#{url}/#{database}")]
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
      db.tables.each { db.drop_table(_1) }
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

  describe "CHECKSUM TABLE" do
    let(:recorder) { TapeDeck::Recorder.new(dbs) }

    it "returns a checksum for every table" do
      snapshot = recorder.snapshot

      expect(snapshot.transform_values(&:keys)).to eq("shop" => %w[orders tags], "billing" => %w[invoices])
      expect(snapshot.values.flat_map(&:values).map(&:checksum)).to all(be_a(Integer))
    end

    it "reuses the snapshot of unchanged tables" do
      before = recorder.snapshot
      shop[:orders].where(id: 1).update(status: "paid")
      after = recorder.snapshot(previous: before)

      expect(after.dig("shop", "tags")).to equal(before.dig("shop", "tags"))
      expect(after.dig("billing", "invoices")).to equal(before.dig("billing", "invoices"))
      expect(after.dig("shop", "orders")).not_to equal(before.dig("shop", "orders"))
    end

    it "skips excluded tables" do
      recorder = TapeDeck::Recorder.new(dbs, exclude_tables: ["shop.tags"])

      expect(recorder.snapshot["shop"].keys).to eq(%w[orders])
    end

    it "does not snapshot views" do
      shop.create_view(:new_orders, shop[:orders].where(status: "new"))

      expect(recorder.snapshot["shop"].keys).to eq(%w[orders tags])
    end

    it "snapshots included views as a multiset of rows" do
      shop.create_view(:new_orders, shop[:orders].where(status: "new"))
      recorder = TapeDeck::Recorder.new(dbs, include_views: ["shop.new_*"])

      diff = recorder.record { shop[:orders].insert(status: "new", note: "b") }

      expect(diff.dig("shop", "new_orders")).to eq("inserted" => [{"id" => 2, "status" => "new", "note" => "b"}])
      expect(recorder.resolve.dig("shop", "views")).to eq(%w[new_orders])
    end
  end

  describe ".use_tape" do
    it "records changes across databases" do
      TapeDeck.use_tape("checkout") { checkout }

      expect(YAML.safe_load_file(tape_file("checkout")).fetch("diff")).to eq(
        "billing" => {"invoices" => {"inserted" => [{"id" => 1, "order_id" => 2}]}},
        "shop" => {
          "orders" => {
            "inserted" => [{"id" => 2, "status" => "new", "note" => "n"}],
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

  describe "values" do
    before do
      shop.create_table(:values) do
        primary_key :id
        column :short_bin, "varbinary(16)"
        column :text_bin, "varbinary(16)"
        column :long_bin, "blob"
        column :amount, "decimal(10,2)"
        column :at, "datetime(6)"
        column :on, "date"
        column :clock, "time"
        column :precise_clock, "time(6)"
        column :flag, "tinyint(1)"
        column :json, "json"
      end
    end

    let(:long_bin) { "\xFF".b * 100 }

    it "serializes them to plain YAML scalars" do
      diff = TapeDeck::Recorder.new({"shop" => shop}).record do
        shop[:values].insert(
          short_bin: Sequel.blob("\xFF\x00".b),
          text_bin: Sequel.blob("hello"),
          long_bin: Sequel.blob(long_bin),
          amount: BigDecimal("12.50"),
          # Sequel only writes fractional seconds with the :fractional_seconds option, so write it like a project would
          at: Sequel.lit("'2026-01-02 03:04:05.123456'"),
          on: Date.new(2026, 1, 2),
          clock: Sequel::SQLTime.create(12, 34, 56),
          precise_clock: Sequel.lit("'12:34:56.789012'"),
          flag: true,
          json: '{"a": 1}'
        )
      end
      row = diff.dig("shop", "values", "inserted", 0)

      expect(row).to eq(
        "id" => 1,
        "short_bin" => "0xff00",
        "text_bin" => "hello",
        "long_bin" => "sha256:#{Digest::SHA256.hexdigest(long_bin)}",
        "amount" => "12.5",
        "at" => "2026-01-02T03:04:05.123456Z",
        "on" => "2026-01-02",
        "clock" => "12:34:56.000000",
        "precise_clock" => "12:34:56.789012",
        "flag" => true,
        "json" => '{"a": 1}'
      )
      expect(YAML.safe_load(TapeDeck::Tape.serialize(diff))).to eq(diff)
    end

    it "keeps the time of day of TIME columns outside of UTC" do
      original_tz = ENV["TZ"]
      ENV["TZ"] = "America/New_York"
      diff = TapeDeck::Recorder.new({"shop" => shop}).record do
        shop[:values].insert(at: Sequel.lit("'2026-01-02 03:04:05'"), clock: Sequel.lit("'12:34:56'"))
      end

      expect(diff.dig("shop", "values", "inserted", 0)).to include(
        "at" => "2026-01-02T08:04:05.000000Z",
        "clock" => "12:34:56.000000"
      )
    ensure
      ENV["TZ"] = original_tz
    end
  end
end
