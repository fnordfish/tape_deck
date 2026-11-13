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
        config.expose_dsl_globally = false if config.respond_to?(:expose_dsl_globally=) # RSpec 4 never exposes it
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
        it("creates an order", tape_deck: {tape_name: "/orders/create", record: :overwrite}) { orders.insert(status: "a") }
      end
      reset_tables(db, :orders)
      run_group do
        it("creates an order", tape_deck: {tape_name: "/orders/create", record: :overwrite}) { orders.insert(status: "b") }
      end

      expect(tape("orders/create").dig("shop", "orders", "inserted", 0, "status")).to eq("b")
    end

    it "just runs tagged examples while TapeDeck is turned off" do
      orders = db[:orders]
      TapeDeck.turn_off!
      failure = run_group { it("creates an order", :tape_deck) { orders.insert(status: "new") } }

      expect(failure).to be_nil
      expect(orders.count).to eq(1)
      expect(Dir.glob("#{tape_dir}/**/*.yml")).to be_empty
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

  describe ".check_rspec_tape_names" do
    # Defines examples in a sandbox, without running them
    def examples(&definition)
      RSpec::Core::Sandbox.sandboxed do |config|
        config.expose_dsl_globally = false if config.respond_to?(:expose_dsl_globally=) # RSpec 4 never exposes it
        RSpec.describe("Checkout", &definition).descendants.flat_map(&:examples)
      end
    end

    def check(&definition) = described_class.check_rspec_tape_names(examples(&definition))

    it "accepts examples with their own tapes" do
      expect {
        check do
          %w[paid shipped].each { |status| it("creates an order (#{status})", :tape_deck) {} }
          it("creates an order", tape_deck: {tape_name: "orders/create"}) {}
          it("creates an order") {} # not tagged
        end
      }.not_to raise_error
    end

    it "lists examples that share a tape, like the same description in a loop" do
      expect {
        check { %w[paid shipped].each { it("creates an order", :tape_deck) {} } }
      }.to raise_error(TapeDeck::Error, <<~MESSAGE.chomp)
        TapeDeck: examples share a tape. Give each its own description or tape_name:
          Checkout/creates_an_order.yml:
            ./spec/tape_deck/configuration_spec.rb[1:1] "Checkout/creates an order"
            ./spec/tape_deck/configuration_spec.rb[1:2] "Checkout/creates an order"
      MESSAGE
    end

    it "notices names that only share a file name, and explicit tape names" do
      expect {
        check do
          it("creates an order", :tape_deck) {}
          it("creates_an_order", :tape_deck) {}
          it("anything", tape_deck: {tape_name: "/Checkout/creates an order"}) {}
        end
      }.to raise_error(TapeDeck::Error, /Checkout\/creates_an_order.yml:\n(.*\n){2}.*"Checkout\/creates an order"\z/)
    end
  end

  describe ".rspec_tape" do
    # Defines examples in a sandbox, without running them, and returns their tape names and options
    def tapes(description, metadata = {}, &definition)
      RSpec::Core::Sandbox.sandboxed do |config|
        config.expose_dsl_globally = false if config.respond_to?(:expose_dsl_globally=) # RSpec 4 never exposes it
        examples = RSpec.describe(description, metadata, &definition).descendants.flat_map(&:examples)
        examples.to_h { [_1.description, described_class.rspec_tape(_1)] }
      end
    end

    it "renames only the level tape_name is set on" do
      tapes = tapes("A") do
        context "b", tape_deck: {tape_name: "FOO"} do
          context "c" do
            it("bar", :tape_deck) {}
            it("baz", tape_deck: {tape_name: "qux"}) {}
          end
        end
      end

      expect(tapes.transform_values(&:first)).to eq("bar" => "A/FOO/c/bar", "baz" => "A/FOO/c/qux")
    end

    it "replaces the whole name up to its level with a leading /" do
      tapes = tapes("Checkout") do
        context "paying", tape_deck: {tape_name: "/payments"} do
          it("by card", :tape_deck) {}
        end
        it("creates an order", tape_deck: {tape_name: "/orders/create"}) {}
      end

      expect(tapes.transform_values(&:first)).to eq("by card" => "payments/by card", "creates an order" => "orders/create")
    end

    it "merges options from the outermost group down to the example, inner ones winning" do
      tapes = tapes("Checkout", tape_deck: {databases: %w[shop], only: "shop.orders"}) do
        context "paying", tape_deck: {ignore: "shop.orders.note"} do
          it("by card", tape_deck: {only: "shop.payments", record: :overwrite}) {}
          it("by invoice", :tape_deck) {}
        end
      end

      expect(tapes.transform_values(&:last)).to eq(
        "by card" => {databases: %w[shop], only: "shop.payments", ignore: "shop.orders.note", record: :overwrite},
        "by invoice" => {databases: %w[shop], only: "shop.orders", ignore: "shop.orders.note"}
      )
    end
  end
end
