# frozen_string_literal: true

require "rspec/core/sandbox"

RSpec.describe TapeDeck::Configuration do
  describe "#default_record_mode=" do
    it "rejects unknown record modes" do
      expect { described_class.new.default_record_mode = :all }.to raise_error(ArgumentError, /invalid record mode :all/)
    end
  end

  describe "#on_schema_change=" do
    it "rejects unknown actions" do
      expect { described_class.new.on_schema_change = :fail }
        .to raise_error(ArgumentError, /invalid schema change action :fail/)
    end
  end

  describe "#configure_rspec_metadata!" do
    let(:db) { sqlite_db }
    let(:tape_dir) { TapeDeck.configuration.tape_library_dir }

    before do
      db.create_table(:orders) do
        primary_key :id
        String :status
      end
      TapeDeck.configure { |c| c.databases = {"shop" => db} }
    end

    # Runs an example group in a sandbox, so the hook is not installed in the real suite.
    #
    # @return [Exception, nil] the exception of the first example that failed
    def run_group(&definition)
      RSpec::Core::Sandbox.sandboxed do |config|
        config.expose_dsl_globally = false
        TapeDeck.configuration.configure_rspec_metadata!
        group = RSpec.describe("Checkout", &definition)
        group.run(RSpec::Core::NullReporter)
        group.descendants.flat_map(&:examples).filter_map { _1.execution_result.exception }.first
      end
    end

    def tape(name) = YAML.safe_load_file(File.join(tape_dir, "#{name}.yml")).fetch("diff")

    it "names the tape after the description hierarchy for a bare tag" do
      orders = db[:orders]
      failure = run_group do
        describe "ordering" do
          it("creates an order", :tape_deck) { orders.insert(status: "new") }
        end
      end

      expect(failure).to be_nil
      expect(tape("Checkout/ordering/creates_an_order").dig("shop", "orders", "inserted")).to eq([{"id" => "new shop.orders 1", "status" => "new"}])
    end

    it "passes options and a custom tape name" do
      orders = db[:orders]
      run_group do
        it("creates an order", tape_deck: {tape_name: "orders/create", record: :overwrite}) { orders.insert(status: "a") }
      end
      reset_tables(db, :orders)
      run_group do
        it("creates an order", tape_deck: {tape_name: "orders/create", record: :overwrite}) { orders.insert(status: "b") }
      end

      expect(tape("orders/create").dig("shop", "orders", "inserted", 0, "status")).to eq("b")
    end

    it "discards the tape when the example fails" do
      orders = db[:orders]
      failure = run_group do
        it("fails", :tape_deck) do
          orders.insert(status: "new")
          raise "boom"
        end
      end

      expect(failure.message).to eq("boom")
      expect(Dir.glob("#{tape_dir}/**/*.yml")).to be_empty
    end

    it "fails the example when the tape does not match" do
      orders = db[:orders]
      run_group { it("creates", :tape_deck) { orders.insert(status: "new") } }
      reset_tables(db, :orders)

      failure = run_group { it("creates", :tape_deck) { orders.insert(status: "paid") } }

      expect(failure).to be_a(TapeDeck::UnexpectedDiffError)
      expect(failure.message).to match(/^-\s+status: new$/).and match(/^\+\s+status: paid$/)
    end
  end
end
