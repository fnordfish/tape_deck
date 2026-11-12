# frozen_string_literal: true

require "delegate"
require "ipaddr"

RSpec.describe TapeDeck::Adapters do
  describe ".for" do
    it "picks the adapter by database type" do
      expect(described_class.for(Sequel.mock(host: "mysql"))).to be_a(TapeDeck::Adapters::MySQL)
      expect(described_class.for(Sequel.mock(host: "postgres"))).to be_a(TapeDeck::Adapters::Postgres)
      expect(described_class.for(sqlite_db)).to be_a(TapeDeck::Adapters::SQLite)
    end

    it "falls back to the generic adapter" do
      expect(described_class.for(Sequel.mock(host: "oracle")).class).to eq(TapeDeck::Adapters::Base)
    end
  end

  describe TapeDeck::Adapters::Base do
    subject(:adapter) { described_class.new(sqlite_db) }

    it "has no checksums" do
      expect(adapter.checksums(%w[orders tags])).to eq("orders" => nil, "tags" => nil)
    end

    it "turns hash-like and array-like values into plain ones" do
      json = DelegateClass(Hash).new({"a" => [BigDecimal("1.5")], :b => nil})
      array = DelegateClass(Array).new([1, "x"])

      expect(adapter.serialize(json)).to eq("a" => ["1.5"], "b" => nil)
      expect(adapter.serialize(array)).to eq([1, "x"])
      expect(YAML.safe_load(YAML.dump(adapter.serialize(json)))).to eq("a" => ["1.5"], "b" => nil)
    end

    it "turns other unknown values into strings" do
      expect(adapter.serialize(IPAddr.new("10.0.0.1"))).to eq("10.0.0.1")
    end

    it "turns string subclasses into plain strings" do
      expect(adapter.serialize(Sequel.lit("x"))).to be_instance_of(String)
    end

    it "keeps the time of day of TIME columns returned as Time" do
      expect(adapter.serialize(Time.new(2000, 1, 1, 12, 34, 56.5), {db_type: "time(6)"})).to eq("12:34:56.500000")
      expect(adapter.serialize(Time.utc(2026, 1, 2, 3, 4, 5), {db_type: "datetime"})).to eq("2026-01-02T03:04:05.000000Z")
    end
  end

  describe TapeDeck::Adapters::MySQL do
    it "uses CHECKSUM TABLE" do
      db = Sequel.mock(host: "mysql", fetch: [{Table: "tape_deck_shop.orders", Checksum: 42}, {Table: "tape_deck_shop.tags", Checksum: nil}])

      expect(described_class.new(db).checksums(%w[orders tags])).to eq("orders" => 42, "tags" => nil)
      expect(db.sqls).to eq(["CHECKSUM TABLE `orders`, `tags`"])
    end

    it "queries nothing without tables" do
      db = Sequel.mock(host: "mysql")

      expect(described_class.new(db).checksums([])).to eq({})
      expect(db.sqls).to be_empty
    end
  end

  describe TapeDeck::Adapters::Postgres do
    it "computes checksums on the server, in one query" do
      db = Sequel.mock(host: "postgres", fetch: [{name: "orders", sum: "2:123"}, {name: "tags", sum: "0:0"}])

      expect(described_class.new(db).checksums(%w[orders tags])).to eq("orders" => "2:123", "tags" => "0:0")
      sqls = db.sqls
      expect(sqls.size).to eq(1)
      expect(sqls.first).to include(%(FROM "orders" AS tape_deck_row UNION ALL SELECT 'tags'))
    end
  end
end
