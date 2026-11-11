# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../spec_helper"

# OP#1843: Schatten-Messung. Gemessen wird nur, was ein MENSCH beantwortet hat; nichts wird automatisch beantwortet.
RSpec.describe Flightplan::Shadow do
  let(:project) { create(:project) }
  let(:role) { create(:project_role, permissions: %i[view_work_packages add_work_package_comments]) }
  let(:agent) { create(:user, member_with_roles: { project => role }) }
  let(:admin) { create(:admin, member_with_roles: { project => role }) }
  let(:work_package) { create(:work_package, project:, author: agent) }

  def ask(attributes = {})
    Flightplan::Question.create!(
      { work_package:, author: agent, question: "Welche Variante?", options: %w[A B], status: "open" }.merge(attributes)
    )
  end

  def answer(question, **args)
    Flightplan::Questions::Answer.call(user: admin, question:, **args)
  end

  describe "when a human answers a question over ask" do
    it "writes a row with a recommendation: matched and would_auto for a clean reversible decision" do
      question = ask(kind: "entscheidung", recommended_option: "A", reversible: true, context: "Nur Optik")
      answer(question, option: "A")

      row = Flightplan::ShadowDecision.sole
      expect(row).to have_attributes(source: "ask", work_package_id: work_package.id, question_id: question.id, request_id: nil,
                                     kind: "entscheidung", reversible: true, recommended: "A", chosen: "A", matched: true,
                                     would_auto: true)
      expect(row.rule).to eq("SHADOW_RULE_V1: ja")
    end

    it "marks matched false when the human chose another option" do
      answer(ask(kind: "entscheidung", recommended_option: "A", reversible: true), option: "B")

      expect(Flightplan::ShadowDecision.sole).to have_attributes(chosen: "B", matched: false, would_auto: true)
    end

    it "records free text as <Freitext> and never as matched" do
      answer(ask(recommended_option: "A"), text: "etwas ganz anderes")

      expect(Flightplan::ShadowDecision.sole).to have_attributes(chosen: "<Freitext>", matched: false)
    end

    it "writes no row without a recommendation" do
      answer(ask(kind: "entscheidung", reversible: true), option: "A")
      answer(ask, text: "frei")

      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "says why the rule would not have decided" do
      answer(ask(kind: "freigabe", recommended_option: "A", reversible: true), option: "A")
      answer(ask(kind: "entscheidung", recommended_option: "A", reversible: false), option: "A")
      answer(ask(kind: "entscheidung", recommended_option: "A", reversible: true, question: "Docker neu starten?"), option: "A")

      rows = Flightplan::ShadowDecision.order(:id)
      expect(rows.map(&:would_auto)).to eq([false, false, false])
      expect(rows.map(&:matched)).to eq([true, true, true])
      expect(rows[0].rule).to include("entscheidung")
      expect(rows[1].rule).to include("umkehrbar")
      expect(rows[2].rule).to include("Vorbehaltswort")
    end

    it "does not change the answer when the measurement fails" do
      allow(Flightplan::ShadowDecision).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "kaputt")
      question = ask(recommended_option: "A")

      expect { answer(question, option: "A") }.not_to raise_error
      expect(question.reload).not_to be_open
    end
  end

  describe "no answering without a human" do
    it "leaves a question with recommendation, kind and reversible open, however clean the rule finds it" do
      question = ask(kind: "entscheidung", recommended_option: "A", reversible: true)

      expect(Flightplan::ShadowRule.call(source: "ask", kind: "entscheidung", reversible: true, recommended: "A",
                                         texts: [question.question, question.options]).would_auto).to be(true)
      described_class.summary

      question.reload
      expect(question).to be_open
      expect(question.chosen_option).to be_nil
      expect(question.answered_by).to be_nil
      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "refuses an agent answer and writes nothing" do
      question = ask(kind: "entscheidung", recommended_option: "A", reversible: true)

      expect { Flightplan::Questions::Answer.call(user: agent, question:, option: "A") }
        .to raise_error(Flightplan::Questions::Answer::Forbidden)
      expect(question.reload).to be_open
      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "has no public way to answer from the rule or the measurement" do
      expect(Flightplan::ShadowRule.methods(false)).not_to include(:answer)
      expect(described_class.methods(false)).to contain_exactly(:record_ask, :record_chat, :summary)
    end
  end

  describe ".record_chat" do
    it "writes a chat row that is never would_auto, and ignores the same request twice" do
      first = described_class.record_chat(work_package:, request_id: "req-1", recommended: "Ja (Recommended)", chosen: "Nein")
      second = described_class.record_chat(work_package:, request_id: "req-1", recommended: "Ja (Recommended)", chosen: "Nein")

      expect(first).to be_present
      expect(second).to be_nil
      expect(Flightplan::ShadowDecision.sole).to have_attributes(source: "chat", question_id: nil, request_id: "req-1", matched: false,
                                                                 would_auto: false)
      expect(Flightplan::ShadowDecision.sole.rule).to include("Chat")
    end

    it "marks matched when the human chose the recommended label" do
      described_class.record_chat(work_package:, request_id: "req-2", recommended: "Ja", chosen: "Ja")

      expect(Flightplan::ShadowDecision.sole.matched).to be(true)
    end
  end

  describe ".summary" do
    def row(matched:, would_auto:, source: "ask")
      Flightplan::ShadowDecision.create!(source:, work_package:, chosen: "A", matched:, would_auto:, rule: "x")
    end

    it "is all zero without rows" do
      expect(described_class.summary).to include(total: 0, matched: 0, would_auto: 0, wrong: 0)
    end

    it "counts wrong only when the rule would have decided and the human chose otherwise" do
      row(matched: true, would_auto: true)
      row(matched: false, would_auto: true)
      row(matched: false, would_auto: false)
      row(matched: true, would_auto: false, source: "chat")

      expect(described_class.summary).to include(total: 4, matched: 2, would_auto: 2, wrong: 1, rule: "SHADOW_RULE_V1",
                                                 by_source: { "ask" => 3, "chat" => 1 })
    end
  end
end
