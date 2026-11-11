# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

# OP#1839: Karte „Ergebnis zur Abnahme“ in „Braucht dich“ (Rang 3) und die Browser-Route zum Entscheiden einer Annahme.
# OP#1840: Hintergrundstart (Knopf, Platzanzeige) und die Nachrichten an den Rahmen.
RSpec.describe "Flightplan Abnahmekarte", :skip_csrf, type: :rails_request do
  def ensure_status(name)
    Status.find_by(name:) || create(:status, name:)
  end

  let!(:task_type) { Type.find_by(name: "Aufgabe") || create(:type, name: "Aufgabe") }
  let!(:project) { create(:project, name: "Abnahme Fabrik", identifier: "abnahme-fabrik", public: false, types: [task_type]) }
  let(:admin) { create(:admin, language: "de") }
  let(:agent) { create(:user, firstname: "Coda", lastname: "Agentin", login: "coda-abnahme") }
  let!(:review_ticket) do
    create(:work_package, project:, type: task_type, status: ensure_status("Review"), subject: "<i>Fertig</i> & prüfbar")
  end
  let!(:working_ticket) do
    create(:work_package, project:, type: task_type, status: ensure_status("In Arbeit"), subject: "Noch dran")
  end
  let!(:waiting_ticket) do
    create(:work_package, project:, type: task_type, status: ensure_status("Wartet auf Mensch"), subject: "Frage offen")
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def note(work_package, text)
    result = AddWorkPackageNoteService.new(user: admin, work_package:).call(text, send_notifications: false)
    raise result.errors.full_messages.to_sentence unless result.success?
  end

  describe "card on the home screen" do
    current_user { admin }

    let(:inbox) { page.at_css("#fp-inbox") }
    let(:rows) { inbox.css("[data-fp-inbox-row]") }

    before do
      note(review_ticket, "PR: https://github.com/rodgi040/openproject/pull/9")
      note(review_ticket, "<!-- fp-result v1 -->\n## Geändert\n<script>alert(1)</script> Modul\n## Geprüft\nSpecs grün\n## Offen\nnichts")
      Flightplan::Assumption.create!(work_package: working_ticket, author: agent, text: "Ich nehme <b>Port</b> 8094")
    end

    it "shows the review ticket with title, PR link and the escaped closing statement" do
      get "/"
      row = rows.find { |item| item["data-id"].to_i == review_ticket.id }
      expect(row).to be_present
      expect(row["data-kind"]).to eq("result")
      expect(row["data-fp-review"]).to eq("1")
      expect(row.at_css(".fp-wl-title").text).to eq("<i>Fertig</i> & prüfbar")
      expect(row.at_css(".fp-wl-title i")).to be_nil
      link = row.at_css("a.fp-result-pr")
      expect(link["href"]).to eq("https://github.com/rodgi040/openproject/pull/9")
      expect(row.css(".fp-result-title").map(&:text)).to eq(%w[Geändert Geprüft Offen])
      expect(row.css(".fp-result-body").map(&:text)).to eq(["<script>alert(1)</script> Modul", "Specs grün", "nichts"])
      expect(row.at_css(".fp-result script")).to be_nil
      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(row.css("[data-fp-assumption]")).to be_empty
    end

    it "shows a ticket with an open assumption, with confirm and reject, and escapes the text" do
      get "/"
      row = rows.find { |item| item["data-id"].to_i == working_ticket.id }
      expect(row).to be_present
      expect(row["data-fp-review"]).to eq("0")
      expect(row.at_css("[data-fp-result-missing]")).to be_present
      assumption = Flightplan::Assumption.last
      expect(row.at_css(".fp-assumption-text").text).to include("Ich nehme <b>Port</b> 8094")
      expect(row.at_css(".fp-assumption-text b")).to be_nil
      form = row.at_css("form[data-fp-assumption-form='#{assumption.id}']")
      expect(form["action"]).to eq("/flightplan/assumptions/#{assumption.id}/decide")
      expect(form.css("button[name='decision']").map { |button| [button["value"], button.text.strip] })
        .to eq([%w[confirmed bestätigen], %w[rejected verwerfen]])
      expect(form.at_css("textarea[name='note']")).to be_present
    end

    it "leaves out tickets that are neither in Review nor have an open assumption" do
      get "/"
      ids = rows.map { |row| row["data-id"].to_i }
      expect(ids).to contain_exactly(review_ticket.id, working_ticket.id)
      expect(ids).not_to include(waiting_ticket.id)
    end

    it "ranks the card third: after approval and question, before failure and input" do
      Flightplan::Question.create!(work_package: waiting_ticket, author: agent, question: "Darf ich?", status: "open")
      get "/"
      expect(rows.map { |row| row["data-kind"] }).to eq(%w[question result result])
      expect(rows.map { |row| row["data-rank"].to_i }).to eq([1, 2, 2])
      expect(rows.map { |row| row["data-id"].to_i }.drop(1)).to eq([working_ticket.id, review_ticket.id])
      expect(Flightplan::Worklist::INBOX_KINDS.index("result")).to eq(2)
      expect(page.at_css("[data-fp-inbox-count]").text.squish).to eq("Braucht dich (3)")
    end

    it "leaves out Review tickets without closing statement and does not count them" do
      bare = create(:work_package, project:, type: task_type, status: ensure_status("Review"), subject: "Altlast ohne Aussage")
      note(bare, "Fertig, glaub mir.")
      get "/"
      expect(rows.map { |row| row["data-id"].to_i }).to contain_exactly(review_ticket.id, working_ticket.id)
      expect(page.at_css("[data-fp-inbox-count]").text.squish).to eq("Braucht dich (2)")
    end

    it "shows who wrote the closing statement and the PR comment, escaped" do
      get "/"
      row = rows.find { |item| item["data-id"].to_i == review_ticket.id }
      expect(row.at_css("[data-fp-result-origin]").text).to include("Abschlussaussage von #{admin.name}")
      expect(row.at_css("[data-fp-pr-origin]").text).to include("von #{admin.name}")
    end

    it "lists assumptions first, notes the cards beyond the limit and keeps the count right" do
      stub_const("Flightplan::Acceptance::LIMIT", 1)
      get "/"
      expect(rows.map { |row| row["data-id"].to_i }).to eq([working_ticket.id])
      expect(inbox["data-fp-more"]).to eq("1")
      expect(inbox.at_css("[data-fp-inbox-more]").text).to include("+1 weitere")
      expect(inbox.at_css("[data-fp-inbox-total]").text).to eq("2")
      expect(page.at_css("[data-fp-inbox-count]").text.squish).to eq("Braucht dich (2)")
    end

    it "does not show guard or diff size, which the module does not know" do
      get "/"
      expect(inbox.text).not_to match(/Guard|Diff/i)
    end

    it "shows the start button on list rows and cards, the slot label and the hint after answering" do
      Flightplan::Question.create!(work_package: waiting_ticket, author: agent, question: "Darf ich?", status: "open")
      get "/"
      expect(page.css("#fp-worklist [data-fp-worklist-row] button[data-fp-start]").map(&:text).uniq.map(&:strip))
        .to eq(["Im Hintergrund starten"])
      expect(page.css("#fp-worklist [data-fp-wl-group='done'] [data-fp-start]")).to be_empty
      expect(page.css("[data-fp-board-card] button[data-fp-start]")).not_to be_empty
      expect(page.at_css("[data-fp-slots]")["data-template"]).to eq("__N__ von 4 Plätzen belegt")
      expect(page.at_css("[data-fp-slots]").key?("hidden")).to be(true)
      labels = JSON.parse(page.at_css("#fp-home")["data-fp-start-labels"])
      expect(labels).to include("slots_full" => "4 von 4 Plätzen belegt", "running" => "läuft schon", "accepted" => "gestartet")
      question_row = rows.find { |row| row["data-kind"] == "question" }
      expect(question_row["data-fp-saved-hint"]).to eq("Antwort gespeichert. Der Agent läuft weiter, solange dieses Dashboard offen ist.")
    end

    it "ships the messages for the frame in the script" do
      get "/flightplan/assets/flightplan.js"
      expect(response.body).to include('type: "fp:assumption"', '"fp:start"', 'data.type === "fp:started"', "function fpStartTicket(node)",
                                       "function fpSlots()", "ticket: ok ?")
    end
  end

  describe "without admin rights" do
    current_user { create(:user, language: "de", member_with_roles: { project => create(:project_role, permissions: %i[view_work_packages]) }) }

    it "shows no acceptance card and no start button" do
      get "/"
      expect(page.css("[data-fp-inbox-row][data-kind='result']")).to be_empty
      expect(page.css("[data-fp-start]")).to be_empty
    end
  end

  describe "POST /flightplan/assumptions/:id/decide" do
    let!(:assumption) { Flightplan::Assumption.create!(work_package: working_ticket, author: agent, text: "Port 8094") }
    let(:json) { { "ACCEPT" => "application/json" } }

    context "as admin" do
      current_user { admin }

      it "confirms with JSON, writes the comment and reports what is left open" do
        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "confirmed" }, headers: json

        expect(response).to have_http_status(:ok), response.body
        payload = JSON.parse(response.body)
        expect(payload).to include("ok" => true, "remaining_open" => 0)
        expect(payload["assumption"]).to include("id" => assumption.id, "work_package_id" => working_ticket.id,
                                                 "status" => "confirmed", "text" => "Port 8094", "decided_by" => admin.login)
        expect(payload["message"]).to eq("Annahme bestätigt – ##{working_ticket.id}")
        expect(assumption.reload.status).to eq("confirmed")
        expect(working_ticket.journals.order(:id).pluck(:notes).compact).to include("Annahme bestätigt")
      end

      it "rejects only with a note" do
        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "rejected", note: " " }, headers: json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(assumption.reload).to be_open

        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "rejected", note: "Nimm 8095" }, headers: json
        expect(response).to have_http_status(:ok), response.body
        expect(JSON.parse(response.body)["assumption"]).to include("status" => "rejected", "note" => "Nimm 8095")
      end

      it "refuses to decide twice with 422" do
        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "confirmed" }, headers: json
        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "rejected", note: "doch" }, headers: json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("Die Annahme ist bereits entschieden")
        expect(assumption.reload.status).to eq("confirmed")
      end

      it "redirects back to the section with a notice without JSON" do
        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "confirmed" }

        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq("Annahme bestätigt – ##{working_ticket.id}")
      end
    end

    context "as a user who is neither admin nor human" do
      let(:member) do
        create(:user, language: "de",
                      member_with_roles: { project => create(:project_role, permissions: %i[view_work_packages]) })
      end

      current_user { member }

      it "answers 403 and keeps the assumption open" do
        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "confirmed" }, headers: json

        expect(response).to have_http_status(:forbidden)
        expect(assumption.reload).to be_open
      end
    end

    context "as a human of another project" do
      let(:mixed) do
        human = create(:project_role, name: "Mensch", permissions: %i[view_work_packages])
        viewer = create(:project_role, name: "Betrachter", permissions: %i[view_work_packages])
        other = create(:project)
        create(:user, language: "de", member_with_roles: { other => human, project => viewer })
      end

      current_user { mixed }

      it "answers 403: the Mensch role does not reach the project of the ticket" do
        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "confirmed" }, headers: json

        expect(response).to have_http_status(:forbidden)
        expect(assumption.reload).to be_open
      end
    end

    context "as a user who cannot see the ticket" do
      current_user { create(:user, language: "de") }

      it "answers 404" do
        post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "confirmed" }, headers: json

        expect(response).to have_http_status(:not_found)
        expect(assumption.reload).to be_open
      end
    end
  end
end

RSpec.describe "Flightplan Abnahmekarte with CSRF protection", type: :rails_request do
  let(:admin) { create(:admin, language: "de") }
  let(:project) { create(:project, public: false) }
  let(:work_package) { create(:work_package, project:, author: admin) }
  let!(:assumption) { Flightplan::Assumption.create!(work_package:, author: admin, text: "Mit Token?") }

  current_user { admin }

  around do |example|
    state = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = state
  end

  it "puts the CSRF token into the form and rejects a decision without it" do
    get "/"
    form = Nokogiri::HTML(response.body).at_css("form[data-fp-assumption-form]")
    expect(form.at_css("input[name='authenticity_token']")["value"]).to be_present

    post "/flightplan/assumptions/#{assumption.id}/decide", params: { decision: "confirmed" }

    expect(assumption.reload).to be_open
  end
end
