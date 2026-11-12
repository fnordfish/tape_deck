# frozen_string_literal: true

RSpec.describe TapeDeck::Tape do
  let(:tape_deck) do
    {
      "exclude_tables" => ["shop.sessions"],
      "exclude_columns" => ["*.created_at"],
      "include_views" => ["shop.order_totals"],
      "keep_new_ids" => ["shop.audit_log"],
      "number_by_content" => ["shop.imports"],
      "generated_keys" => ["shop.tokens.id"],
      "references_to" => {"shop.orders" => ["billing.invoices.order_id", "*.last_order_id"]},
      "databases" => {
        "shop" => {"excluded" => ["orders.created_at", "sessions"], "views" => ["order_totals"]},
        "billing" => {"excluded" => [], "views" => []}
      }
    }
  end

  def write_tape(name, diff = {}, tape_deck: TapeDeck::Tape::RULES.to_h { [_1, []] }.merge("references_to" => {}, "databases" => {}))
    described_class.new(name, record: :overwrite).write(diff, tape_deck: tape_deck)
  end

  it "builds the file path from the tape library and a sanitized name" do
    tape = described_class.new("checkout/creates an order!")

    expect(tape.file_name).to eq("checkout/creates_an_order_.yml")
    expect(tape.file).to eq(File.join(TapeDeck.configuration.tape_library_dir, "checkout/creates_an_order_.yml"))
  end

  it "defaults the record mode to the configured one" do
    TapeDeck.configuration.default_record_mode = :overwrite

    expect(described_class.new("t").record_mode).to eq(:overwrite)
  end

  it "rejects unknown record modes" do
    expect { described_class.new("t", record: :all) }.to raise_error(ArgumentError, /invalid record mode :all/)
  end

  it "rejects unknown options" do
    expect { described_class.new("t", playback: true) }.to raise_error(ArgumentError, /unknown keyword/)
  end

  describe "record mode :once" do
    it "records a missing tape" do
      tape = described_class.new("t", record: :once)

      expect(tape).to be_recording
      expect(tape).not_to be_verifying
    end

    it "verifies an existing tape" do
      write_tape("t")

      expect(described_class.new("t", record: :once)).to be_verifying
    end
  end

  describe "record mode :verify" do
    it "raises for a missing tape" do
      expect { described_class.new("t", record: :verify) }.to raise_error(TapeDeck::TapeLoadingError, /t\.yml/)
    end

    it "verifies an existing tape" do
      write_tape("t")

      expect(described_class.new("t", record: :verify)).to be_verifying
    end
  end

  describe "record mode :overwrite" do
    it "records even if the tape exists" do
      write_tape("t")

      expect(described_class.new("t", record: :overwrite)).to be_recording
    end
  end

  describe "#read" do
    let(:tape) { described_class.new("t", record: :overwrite) }

    def write_file(content)
      FileUtils.mkdir_p(File.dirname(tape.file))
      File.write(tape.file, content)
    end

    it "raises for invalid YAML" do
      write_file("shop: [")

      expect { tape.read }.to raise_error(TapeDeck::TapeLoadingError, /cannot load tape .*t\.yml/) { |error|
        expect(error.cause).to be_a(Psych::SyntaxError)
      }
    end

    it "raises for YAML that is not safe to load" do
      write_file("--- !ruby/object:Object {}\n")

      expect { tape.read }.to raise_error(TapeDeck::TapeLoadingError, /cannot load tape/)
    end

    it "raises for a file that does not hold a recording" do
      write_file("")

      expect { tape.read }.to raise_error(TapeDeck::TapeLoadingError, /does not hold a recording/)
    end

    it "raises for a tape without a tape_deck section" do
      write_file("shop:\n  orders: {}\n")

      expect { tape.read }.to raise_error(TapeDeck::TapeLoadingError, /does not hold a recording/)
    end
  end

  it "writes and reads back a diff, creating subdirectories" do
    diff = {"shop" => {"orders" => {"inserted" => [{"id" => 1, "note" => "a: b"}]}}}
    write_tape("a/b/c", diff, tape_deck: tape_deck)

    expect(described_class.new("a/b/c").read).to eq("tape_deck" => {"version" => TapeDeck::VERSION, **tape_deck}, "diff" => diff)
  end

  it "writes lists on one line, and leaves out empty ones" do
    write_tape("t", {}, tape_deck: tape_deck)

    expect(File.read(described_class.new("t").file)).to eq(<<~YAML)
      ---
      tape_deck:
        version: #{TapeDeck::VERSION}
        exclude_tables: [shop.sessions]
        exclude_columns: ["*.created_at"]
        include_views: [shop.order_totals]
        keep_new_ids: [shop.audit_log]
        number_by_content: [shop.imports]
        generated_keys: [shop.tokens.id]
        references_to:
          shop.orders: [billing.invoices.order_id, "*.last_order_id"]
        databases:
          shop:
            excluded: [orders.created_at, sessions]
            views: [order_totals]
          billing:
      diff: {}
    YAML
  end

  it "reads a tape without recording rules" do
    no_rules = TapeDeck::Tape::RULES.to_h { [_1, []] }.merge("references_to" => {})
    write_tape("t", {}, tape_deck: tape_deck.merge(no_rules))

    expect(described_class.new("t").read.fetch("tape_deck")).to include(no_rules)
  end
end
