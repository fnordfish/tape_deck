# frozen_string_literal: true

# Runs against a real PostgreSQL server. Set TAPE_DECK_POSTGRES_URL to a server URL without a database, e.g.
# "postgres://postgres:tape_deck@postgres". See .devcontainer/compose.yml.
RSpec.describe "PostgreSQL", :postgres do
  def server_url = ENV.fetch("TAPE_DECK_POSTGRES_URL")

  def create_database(server, name)
    server.run("DROP DATABASE IF EXISTS #{name}")
    server.run("CREATE DATABASE #{name}")
  end

  include_examples "a database server"

  it "sees only the tables in the search path" do
    shop.run("DROP SCHEMA IF EXISTS other CASCADE")
    shop.run("CREATE SCHEMA other")
    shop.run("CREATE TABLE other.hidden (id integer)")

    expect(TapeDeck::Recorder.new(dbs).snapshot["shop"].keys).to eq(%w[orders tags])
  ensure
    shop.run("DROP SCHEMA IF EXISTS other CASCADE")
  end

  describe "values" do
    before do
      shop.create_table(:values) do
        primary_key :id
        column :short_bin, "bytea"
        column :text_bin, "bytea"
        column :long_bin, "bytea"
        column :amount, "numeric(10,2)"
        column :at, "timestamp(6)"
        column :at_zone, "timestamptz"
        column :on, "date"
        column :clock, "time"
        column :precise_clock, "time(6)"
        column :flag, "boolean"
        column :json, "json"
        column :jsonb, "jsonb"
        column :tags, "text[]"
        column :ip, "inet"
        column :uid, "uuid"
      end
    end

    let(:long_bin) { "\xFF".b * 100 }

    def insert_values(db)
      db[:values].insert(
        short_bin: Sequel.blob("\xFF\x00".b),
        text_bin: Sequel.blob("hello"),
        long_bin: Sequel.blob(long_bin),
        amount: BigDecimal("12.50"),
        at: Sequel.lit("'2026-01-02 03:04:05.123456'"),
        at_zone: Sequel.lit("'2026-01-02 03:04:05.123456+00'"),
        on: Date.new(2026, 1, 2),
        clock: Sequel::SQLTime.create(12, 34, 56),
        precise_clock: Sequel.lit("'12:34:56.789012'"),
        flag: true,
        json: '{"a": 1}',
        jsonb: '{"a": 1}',
        tags: Sequel.lit("'{a,b}'"),
        ip: "10.0.0.1",
        uid: "0b1c2d3e-0000-4000-8000-000000000001"
      )
    end

    def inserted_row(db)
      diff = TapeDeck::Recorder.new({"shop" => db}).record { insert_values(db) }
      expect(YAML.safe_load(TapeDeck::Tape.serialize(diff))).to eq(diff)
      diff.dig("shop", "values", "inserted", 0)
    end

    it "serializes them to plain YAML scalars" do
      expect(inserted_row(shop)).to eq(
        "id" => 1,
        "short_bin" => "0xff00",
        "text_bin" => "hello",
        "long_bin" => "sha256:#{Digest::SHA256.hexdigest(long_bin)}",
        "amount" => "12.5",
        "at" => "2026-01-02T03:04:05.123456Z",
        "at_zone" => "2026-01-02T03:04:05.123456Z",
        "on" => "2026-01-02",
        "clock" => "12:34:56.000000",
        "precise_clock" => "12:34:56.789012",
        "flag" => true,
        "json" => '{"a": 1}',
        "jsonb" => '{"a": 1}',
        "tags" => "{a,b}",
        "ip" => "10.0.0.1",
        "uid" => "0b1c2d3e-0000-4000-8000-000000000001"
      )
    end

    it "serializes values of Sequel's pg extensions to plain YAML values" do
      db = Sequel.connect("#{server_url}/#{database_names.fetch("shop")}")
      db.extension :pg_json, :pg_array, :pg_inet

      expect(inserted_row(db)).to include(
        "json" => {"a" => 1},
        "jsonb" => {"a" => 1},
        "tags" => %w[a b],
        "ip" => "10.0.0.1"
      )
    ensure
      db&.disconnect
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
