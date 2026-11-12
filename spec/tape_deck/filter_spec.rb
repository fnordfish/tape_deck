# frozen_string_literal: true

RSpec.describe TapeDeck::Filter do
  let(:diff) do
    {
      "shop" => {
        "orders" => {
          "inserted" => [{"id" => 1, "status" => "new", "note" => "b"}, {"id" => 2, "status" => "new", "note" => "a"}],
          "updated" => [{"key" => {"id" => 7}, "changes" => {"status" => %w[new paid], "note" => %w[x y]}}],
          "deleted" => [{"id" => 3, "status" => "old", "note" => "c"}]
        },
        "users" => {"inserted" => [{"id" => 1, "name" => "Bob"}]}
      },
      "billing" => {"invoices" => {"inserted" => [{"id" => 1, "number" => "X-1"}]}}
    }
  end

  it "returns the diff unchanged without rules" do
    expect(described_class.new.apply(diff)).to equal(diff)
  end

  it "keeps only matching columns, and the tables and databases they are in" do
    filtered = described_class.new(only: "shop.orders.status").apply(diff)

    expect(filtered).to eq(
      "shop" => {
        "orders" => {
          "inserted" => [{"status" => "new"}, {"status" => "new"}],
          "updated" => [{"key" => {"id" => 7}, "changes" => {"status" => %w[new paid]}}],
          "deleted" => [{"status" => "old"}]
        }
      }
    )
  end

  it "keeps whole tables matched by only" do
    filtered = described_class.new(only: "shop.users").apply(diff)

    expect(filtered).to eq("shop" => {"users" => {"inserted" => [{"id" => 1, "name" => "Bob"}]}})
  end

  it "drops ignored databases" do
    expect(described_class.new(ignore: "billing.*").apply(diff).keys).to eq(["shop"])
  end

  it "drops ignored columns and updates left without changes" do
    filtered = described_class.new(ignore: ["shop.orders.status", "shop.orders.note"]).apply(diff)

    expect(filtered.dig("shop", "orders")).to eq(
      "inserted" => [{"id" => 1}, {"id" => 2}],
      "deleted" => [{"id" => 3}]
    )
  end

  it "lets ignore win over only" do
    filtered = described_class.new(only: "shop.orders", ignore: "shop.orders.note").apply(diff)

    expect(filtered.dig("shop", "orders", "inserted")).to eq([{"id" => 1, "status" => "new"}, {"id" => 2, "status" => "new"}])
  end
end
