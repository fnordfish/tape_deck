# frozen_string_literal: true

RSpec.describe TapeDeck::Recorder do
  let(:db) { fake_mysql("shop") }
  let(:recorder) { described_class.new({"shop" => db}) }

  before do
    db.create_table(:orders) do
      primary_key :id
      String :status
      String :note
      DateTime :created_at
    end
    db.create_table(:tags) do
      String :name
    end
    db[:orders].insert(id: 1, status: "new", note: "a")
    db[:orders].insert(id: 2, status: "new", note: "b")
    db[:tags].insert(name: "x")
  end

  it "diffs inserted, updated and deleted rows by primary key" do
    diff = recorder.record do
      db[:orders].insert(id: 3, status: "new", note: "c")
      db[:orders].where(id: 1).update(status: "paid")
      db[:orders].where(id: 2).delete
    end

    expect(diff).to eq(
      "shop" => {
        "orders" => {
          "inserted" => [{"id" => 3, "status" => "new", "note" => "c", "created_at" => nil}],
          "updated" => [{"key" => {"id" => 1}, "changes" => {"status" => %w[new paid]}}],
          "deleted" => [{"id" => 2, "status" => "new", "note" => "b", "created_at" => nil}]
        }
      }
    )
  end

  it "diffs tables without a primary key as a multiset" do
    diff = recorder.record do
      db[:tags].insert(name: "y")
      db[:tags].insert(name: "y")
      db[:tags].where(name: "x").delete
    end

    expect(diff.dig("shop", "tags")).to eq(
      "inserted" => [{"name" => "y"}, {"name" => "y"}],
      "deleted" => [{"name" => "x"}]
    )
  end

  it "returns an empty diff when nothing changed" do
    expect(recorder.record {}).to eq({})
  end

  it "reuses the snapshot of tables whose checksum is unchanged" do
    before = recorder.snapshot
    db[:orders].where(id: 1).update(status: "paid")
    after = recorder.snapshot(previous: before)

    expect(after.dig("shop", "tags")).to equal(before.dig("shop", "tags"))
    expect(after.dig("shop", "orders")).not_to equal(before.dig("shop", "orders"))
  end

  it "handles tables created and dropped by the action" do
    diff = recorder.record do
      db.drop_table(:tags)
      db.create_table(:events) { primary_key :id }
      db[:events].insert(id: 1)
    end

    expect(diff).to eq(
      "shop" => {
        "events" => {"inserted" => [{"id" => 1}]},
        "tags" => {"deleted" => [{"name" => "x"}]}
      }
    )
  end

  describe "excluding" do
    let(:recorder) do
      described_class.new({"shop" => db}, exclude_tables: ["shop.tags"], exclude_columns: ["*.note", "*.id"])
    end

    it "never records excluded tables and columns, but keeps primary keys" do
      diff = recorder.record do
        db[:tags].insert(name: "y")
        db[:orders].where(id: 1).update(note: "changed")
        db[:orders].insert(id: 3, status: "new", note: "c")
      end

      expect(diff).to eq("shop" => {"orders" => {"inserted" => [{"id" => 3, "status" => "new", "created_at" => nil}]}})
    end
  end

  describe "values" do
    before do
      db.create_table(:values) do
        primary_key :id
        File :blob
        BigDecimal :amount, size: [10, 2]
        DateTime :at
        Date :on
      end
    end

    def inserted_row(**values)
      recorder.record { db[:values].insert(id: 1, **values) }.dig("shop", "values", "inserted", 0)
    end

    it "keeps binary that is valid UTF-8 as a plain string" do
      row = inserted_row(blob: Sequel.blob("hello"))

      expect(row["blob"]).to eq("hello")
      expect(row["blob"]).to be_instance_of(String)
      expect(row["blob"].encoding).to eq(Encoding::UTF_8)
    end

    it "shows short binary as hex" do
      expect(inserted_row(blob: Sequel.blob("\xFF\x00".b))["blob"]).to eq("0xff00")
    end

    it "shows long binary as a digest" do
      data = "\xFF".b * 65

      expect(inserted_row(blob: Sequel.blob(data))["blob"]).to eq("sha256:#{Digest::SHA256.hexdigest(data)}")
    end

    it "serializes decimals, times and dates as strings" do
      row = inserted_row(amount: BigDecimal("12.50"), at: Time.utc(2026, 1, 2, 3, 4, 5), on: Date.new(2026, 1, 2))

      expect(row).to include("amount" => "12.5", "at" => "2026-01-02T03:04:05.000000Z", "on" => "2026-01-02")
    end
  end
end
