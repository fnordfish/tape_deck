# frozen_string_literal: true

# Runs against a real MySQL server. Set TAPE_DECK_MYSQL_URL to a server URL without a database, e.g.
# "mysql2://root:tape_deck@mysql", "trilogy://root:tape_deck@mysql" or "mysql://root:tape_deck@mysql" (ruby-mysql).
# See .devcontainer/compose.yml.
RSpec.describe "MySQL", :mysql do
  def server_url = ENV.fetch("TAPE_DECK_MYSQL_URL")

  def create_database(server, name) = server.run("CREATE DATABASE IF NOT EXISTS #{name}")

  include_examples "a database server"

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
