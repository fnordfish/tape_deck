# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe TapeDeck::UnexpectedDiffError do
  it "shows the diff outside of RSpec too, like in a Minitest suite or a script" do
    script = <<~RUBY
      require "tape_deck"
      tape = Struct.new(:file).new("spec/db_tapes/checkout.yml")
      puts TapeDeck::UnexpectedDiffError.new(tape, {"status" => "new"}, {"status" => "paid"}).message
    RUBY
    lib = File.expand_path("../../lib", __dir__)

    output, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)

    expect(status).to be_success, output
    expect(output).to include("does not match tape spec/db_tapes/checkout.yml")
    expect(output).to match(/^-status: new$/).and match(/^\+status: paid$/)
  end
end
