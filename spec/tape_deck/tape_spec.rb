# frozen_string_literal: true

RSpec.describe TapeDeck::Tape do
  let(:recorded) do
    {
      "exclude_tables" => ["shop.sessions"],
      "exclude_columns" => ["*.created_at"],
      "databases" => {"shop" => ["orders.created_at", "sessions"], "billing" => []}
    }
  end

  def write_tape(name, diff = {}, recorded: {"exclude_tables" => [], "exclude_columns" => [], "databases" => {}})
    described_class.new(name, record: :overwrite).write(diff, recorded: recorded)
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

    it "raises for a tape without a recorded section" do
      write_file("shop:\n  orders: {}\n")

      expect { tape.read }.to raise_error(TapeDeck::TapeLoadingError, /does not hold a recording/)
    end
  end

  it "writes and reads back a diff, creating subdirectories" do
    diff = {"shop" => {"orders" => {"inserted" => [{"id" => 1, "note" => "a: b"}]}}}
    write_tape("a/b/c", diff, recorded: recorded)

    expect(described_class.new("a/b/c").read).to eq("recorded" => recorded, "diff" => diff)
  end

  it "writes lists on one line, and leaves out empty ones" do
    write_tape("t", {}, recorded: recorded)

    expect(File.read(described_class.new("t").file)).to eq(<<~YAML)
      ---
      recorded:
        exclude_tables: [shop.sessions]
        exclude_columns: ["*.created_at"]
        databases:
          shop:
            excluded: [orders.created_at, sessions]
          billing:
      diff: {}
    YAML
  end

  it "reads a tape without exclude rules" do
    write_tape("t", {}, recorded: recorded.merge("exclude_tables" => [], "exclude_columns" => []))

    expect(described_class.new("t").read.fetch("recorded")).to include("exclude_tables" => [], "exclude_columns" => [])
  end
end
