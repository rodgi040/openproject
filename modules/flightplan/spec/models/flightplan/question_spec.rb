# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../spec_helper"

RSpec.describe Flightplan::Question do
  let(:project) { create(:project) }
  let(:author) { create(:user) }
  let(:work_package) { create(:work_package, project:, author:) }

  subject(:question) do
    described_class.new(
      work_package:,
      author:,
      question: "Weiter?",
      status: "open",
      options: ["ja", "nein"]
    )
  end

  it "is valid with a work package, an author and a question" do
    expect(question).to be_valid
  end

  it "rejects a blank question and an unknown status" do
    question.question = " "
    question.status = "closed"
    expect(question).not_to be_valid
    expect(question.errors.details[:question]).to be_present
    expect(question.errors.details[:status]).to be_present
  end

  it "rejects options that are not strings" do
    question.options = [1]
    expect(question).not_to be_valid
  end

  it "orders open questions oldest first" do
    older = described_class.create!(
      work_package:,
      author:,
      question: "erste",
      status: "open",
      created_at: 2.hours.ago
    )
    newer = described_class.create!(
      work_package:,
      author:,
      question: "zweite",
      status: "open",
      created_at: 1.hour.ago
    )
    described_class.create!(
      work_package:,
      author:,
      question: "weg",
      status: "answered"
    )

    expect(described_class.open.oldest_first).to eq([older, newer])
  end
end

RSpec.describe Flightplan::Question, "structure (OP#1842)" do
  let(:project) { create(:project) }
  let(:author) { create(:user) }
  let(:work_package) { create(:work_package, project:, author:) }

  def build(extra = {})
    described_class.new({ work_package:, author:, question: "Weiter?", status: "open", options: %w[ja nein] }.merge(extra))
  end

  it "is valid with all structured fields unset (old form)" do
    expect(build).to be_valid
  end

  it "is valid with a known kind, a recommended option and a short consequence" do
    expect(build(kind: "freigabe", recommended_option: "ja", reversible: false, consequence: "x" * 500)).to be_valid
  end

  it "rejects an unknown kind, a foreign recommendation and a long consequence" do
    expect(build(kind: "auto")).not_to be_valid
    expect(build(recommended_option: "vielleicht")).not_to be_valid
    expect(build(consequence: "x" * 501)).not_to be_valid
  end
end
