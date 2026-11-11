# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../spec_helper"

# OP#1839: Leser der Abschlussaussage (Marker in der ersten Zeile) und die Zeilen der Abnahmekarte.
RSpec.describe Flightplan::Acceptance do
  let(:marker) { "<!-- fp-result v1 -->" }

  describe ".parse_result" do
    it "reads the three sections when the first line is the marker" do
      text = "#{marker}\n## Geändert\nA geändert\n\n## Geprüft\nSpecs grün\n## Offen\n- nichts\n"

      result = described_class.parse_result(text)

      expect(result.changed).to eq("A geändert")
      expect(result.checked).to eq("Specs grün")
      expect(result.open_points).to eq("- nichts")
    end

    it "ignores a comment without the marker or with the marker below the first line" do
      expect(described_class.parse_result("## Geändert\nX\n## Geprüft\nY\n## Offen\nZ")).to be_nil
      expect(described_class.parse_result("Vorwort\n#{marker}\n## Geändert\nX")).to be_nil
      expect(described_class.parse_result(nil)).to be_nil
    end

    it "keeps HTML as plain text (the view escapes it)" do
      result = described_class.parse_result("#{marker}\n## Geändert\n<script>alert(1)</script>\n## Geprüft\n-\n## Offen\n-")

      expect(result.changed).to eq("<script>alert(1)</script>")
    end
  end

  describe ".pull_request_in" do
    it "takes the URL of the „PR: …“ line that fp-op link-pr writes and nothing else" do
      expect(described_class.pull_request_in("PR: https://github.com/o/r/pull/7")).to eq("https://github.com/o/r/pull/7")
      expect(described_class.pull_request_in("Siehe PR: https://github.com/o/r/pull/7")).to be_nil
      expect(described_class.pull_request_in("PR: javascript:alert(1)")).to be_nil
    end
  end

  describe ".load" do
    let(:permissions) { %i[view_work_packages add_work_package_comments] }
    let(:role) { create(:project_role, permissions:) }
    let(:project) { create(:project) }
    let(:other_project) { create(:project) }
    let(:agent) { create(:user, member_with_roles: { project => role }) }
    let(:viewer) { create(:user, member_with_roles: { project => role }) }
    let!(:review) { Status.find_by(name: "Review") || create(:status, name: "Review") }
    let!(:working) { Status.find_by(name: "In Arbeit") || create(:status, name: "In Arbeit") }

    def note(work_package, text, user: agent)
      result = AddWorkPackageNoteService.new(user:, work_package:).call(text, send_notifications: false)
      raise result.errors.full_messages.to_sentence unless result.success?
    end

    let(:done_text) { "#{marker}\n## Geändert\nX\n## Geprüft\nY\n## Offen\nZ" }

    it "shows tickets with an open assumption and Review tickets WITH a closing statement, but no others, and only visible ones" do
      with_result = create(:work_package, project:, author: agent, status: review)
      note(with_result, done_text)
      without_result = create(:work_package, project:, author: agent, status: review)
      note(without_result, "Fertig, glaub mir.")
      assumed = create(:work_package, project:, author: agent, status: working)
      _plain = create(:work_package, project:, author: agent, status: working)
      hidden = create(:work_package, project: other_project, author: agent, status: review)
      Flightplan::Assumption.create!(work_package: assumed, author: agent, text: "Port 8094")
      Flightplan::Assumption.create!(work_package: hidden, author: agent, text: "versteckt")
      Flightplan::Assumption.create!(work_package: with_result, author: agent, text: "schon klar", status: "confirmed")

      list = described_class.load(user: viewer)

      expect(list.rows.map(&:id)).to eq([assumed.id, with_result.id])
      expect(list.total).to eq(2)
      expect(list.more).to eq(0)
      expect(list.rows.last).to have_attributes(review: true, assumptions: [])
      expect(list.rows.first.assumptions.map(&:text)).to eq(["Port 8094"])
      expect(described_class.load(user: viewer).rows.map(&:id)).not_to include(without_result.id)
    end

    it "puts assumptions first, then Review tickets, each oldest first" do
      newer_review = create(:work_package, project:, author: agent, status: review)
      older_review = create(:work_package, project:, author: agent, status: review)
      note(older_review, done_text)
      note(newer_review, done_text)
      Journal.where(journable_id: older_review.id).where("notes LIKE ?", "#{marker}%").update_all(created_at: 3.days.ago)
      late = create(:work_package, project:, author: agent, status: working)
      early = create(:work_package, project:, author: agent, status: working)
      Flightplan::Assumption.create!(work_package: late, author: agent, text: "spät", created_at: 1.hour.ago)
      Flightplan::Assumption.create!(work_package: early, author: agent, text: "früh", created_at: 2.days.ago)

      expect(described_class.load(user: viewer).rows.map(&:id)).to eq([early.id, late.id, older_review.id, newer_review.id])
    end

    it "limits the rows, keeps the full total and reports how many are left out" do
      stub_const("Flightplan::Acceptance::LIMIT", 2)
      3.times do |index|
        work_package = create(:work_package, project:, author: agent, status: working)
        Flightplan::Assumption.create!(work_package:, author: agent, text: "A#{index}", created_at: (index + 1).days.ago)
      end

      list = described_class.load(user: viewer)

      expect(list.rows.size).to eq(2)
      expect(list.total).to eq(3)
      expect(list.more).to eq(1)
      expect(Flightplan::Worklist.inbox_count([], list)).to eq(3)
    end

    it "takes the newest comment with the marker as result and the newest „PR:“ comment as pull request, with author and time" do
      work_package = create(:work_package, project:, author: agent, status: review)
      note(work_package, "#{marker}\n## Geändert\nalt\n## Geprüft\nalt\n## Offen\nalt")
      note(work_package, "PR: https://github.com/o/r/pull/1")
      note(work_package, "#{marker}\n## Geändert\nneu\n## Geprüft\nSpecs\n## Offen\n-")
      note(work_package, "## Geändert\nohne Marker, zählt nicht")
      note(work_package, "Hinweis PR: https://github.com/o/r/pull/3 mitten im Text")
      note(work_package, "PR: https://github.com/o/r/pull/2")

      row = described_class.load(user: viewer).rows.find { |item| item.id == work_package.id }

      expect(row.result.changed).to eq("neu")
      expect(row.result.checked).to eq("Specs")
      expect(row.result.by).to eq(agent.name)
      expect(row.result.at).to be_present
      expect(row.pull_request).to eq("https://github.com/o/r/pull/2")
      expect(row.pull_request_by).to eq(agent.name)
      expect(row.pull_request_at).to be_present
    end

    it "ignores a marker that is not on the first line and a newest comment without the marker" do
      work_package = create(:work_package, project:, author: agent, status: review)
      note(work_package, "Vorwort\n#{marker}\n## Geändert\nX")

      expect(described_class.load(user: viewer).rows).to be_empty
    end
  end
end
