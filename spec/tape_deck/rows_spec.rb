# frozen_string_literal: true

RSpec.describe TapeDeck::Rows do
  it "sorts rows by their JSON" do
    rows = [{"id" => 2, "tags" => ["b"]}, {"id" => 1, "tags" => {"x" => nil}}, {"id" => 10, "tags" => nil}]

    expect(described_class.sort(rows)).to eq(rows.sort_by { JSON.generate(_1) })
  end

  it "sorts rows with special floats" do
    rows = [{"x" => Float::INFINITY}, {"x" => Float::NAN}]

    expect(described_class.sort(rows).size).to eq(2)
  end
end
