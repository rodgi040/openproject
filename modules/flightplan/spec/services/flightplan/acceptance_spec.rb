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

    it "shows tickets in Review and tickets with an open assumption, but no others, and only visible ones" do
      in_review = create(:work_package, project:, author: agent, status: review)
      assumed = create(:work_package, project:, author: agent, status: working)
      _plain = create(:work_package, project:, author: agent, status: working)
      hidden = create(:work_package, project: other_project, author: agent, status: review)
      Flightplan::Assumption.create!(work_package: assumed, author: agent, text: "Port 8094")
      Flightplan::Assumption.create!(work_package: hidden, author: agent, text: "versteckt")
      Flightplan::Assumption.create!(work_package: in_review, author: agent, text: "schon klar", status: "confirmed")

      rows = described_class.load(user: viewer)

      expect(rows.map(&:id)).to contain_exactly(in_review.id, assumed.id)
      expect(rows.find { |row| row.id == in_review.id }).to have_attributes(review: true, assumptions: [])
      expect(rows.find { |row| row.id == assumed.id }.assumptions.map(&:text)).to eq(["Port 8094"])
    end

    it "takes the newest comment with the marker as result and the newest „PR:“ comment as pull request" do
      work_package = create(:work_package, project:, author: agent, status: review)
      note(work_package, "#{marker}\n## Geändert\nalt\n## Geprüft\nalt\n## Offen\nalt")
      note(work_package, "PR: https://github.com/o/r/pull/1")
      note(work_package, "#{marker}\n## Geändert\nneu\n## Geprüft\nSpecs\n## Offen\n-")
      note(work_package, "## Geändert\nohne Marker, zählt nicht")
      note(work_package, "PR: https://github.com/o/r/pull/2")

      row = described_class.load(user: viewer).find { |item| item.id == work_package.id }

      expect(row.result.changed).to eq("neu")
      expect(row.result.checked).to eq("Specs")
      expect(row.pull_request).to eq("https://github.com/o/r/pull/2")
    end

    it "has no result when no comment carries the marker" do
      work_package = create(:work_package, project:, author: agent, status: review)
      note(work_package, "Fertig, glaub mir.")

      row = described_class.load(user: viewer).find { |item| item.id == work_package.id }

      expect(row.result).to be_nil
      expect(row.pull_request).to be_nil
    end
  end
end
