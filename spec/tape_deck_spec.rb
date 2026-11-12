# frozen_string_literal: true

RSpec.describe TapeDeck do
  let(:shop) { fake_mysql("shop") }
  let(:billing) { fake_mysql("billing") }

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
              - id: 1
                order_id: 1
          shop:
            orders:
              inserted:
              - id: 1
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
        .to raise_error(TapeDeck::IncompatibleTapeError, /schema changed.*billing: added \["invoices.note"\], removed \[\]/)
    end

    it "notices excluded columns that are gone" do
      shop.alter_table(:orders) { drop_column :note }

      expect { described_class.use_tape("checkout") { shop[:orders].insert(status: "new") } }
        .to raise_error(TapeDeck::IncompatibleTapeError, /shop: added \[\], removed \["orders.note"\]/)
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
