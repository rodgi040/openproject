# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

# OP#1778 Teil 2: Die linke Fläche des Splits hat zwei Ansichten, Board (Standard) und Arbeitsliste. Die Arbeitsliste
# bündelt die Board-Spalten zu Reitern („Für dich“, „Läuft“, „Triage“, „Projekte“) und zeigt je Gruppe vier Zeilen.
RSpec.describe "Flightplan work list", :skip_csrf, type: :rails_request do
  def ensure_status(name)
    Status.find_by(name:) || create(:status, name:)
  end

  let!(:task_type) { Type.find_by(name: "Aufgabe") || create(:type, name: "Aufgabe") }
  let!(:project) { create(:project, name: "Liste Fabrik", identifier: "liste-fabrik", public: false, types: [task_type]) }
  let(:admin) { create(:admin, language: "de") }
  let(:member) { create(:user, language: "de") }

  let!(:waiting) do
    Array.new(5) do |index|
      create(:work_package, project:, type: task_type, status: ensure_status("Wartet auf Mensch"), subject: "Frage #{index}")
    end
  end
  let!(:running) do
    create(:work_package, project:, type: task_type, status: ensure_status("In Arbeit"), subject: "<b>Laeuft</b> & mehr")
  end

  def page
    Nokogiri::HTML(response.body)
  end

  describe "as admin" do
    current_user { admin }

    before { get "/" }

    it "offers Board and Arbeitsliste as views of the left pane, Board first and shown" do
      main = page.at_css("#fp-home > .fp-home-main")
      buttons = main.css("[data-fp-left-views] [data-fp-left-set]")
      expect(buttons.map { |node| [node["data-fp-left-set"], node.text.strip, node["aria-pressed"]] })
        .to eq([["board", "Board", "true"], ["worklist", "Arbeitsliste", "false"]])
      expect(main.at_css("[data-fp-left-view='board']:not([hidden]) #fp-dashboard")).to be_present
      expect(main.at_css("[data-fp-left-view='worklist'][hidden] #fp-worklist")).to be_present
    end

    it "keeps the chat element above both views" do
      main = page.at_css("#fp-home > .fp-home-main")
      picker = main.at_css("[data-fp-chat-tickets]")
      expect(picker).to be_present
      expect(picker.ancestors("[data-fp-left-view]")).to be_empty
      expect(picker.at_css("[data-fp-chat-next]").text).to include("Nächstes")
      expect(picker.at_css("[data-fp-chat-active]")["data-free"]).to eq("Thread ohne Ticket")
    end

    it "has the four tabs in order with counts and the groups of „Für dich“ in order" do
      tabs = page.css("#fp-worklist [role='tablist'] [data-fp-wl-tab]")
      expect(tabs.map { |node| node["data-fp-wl-tab"] }).to eq(%w[fuer_dich laeuft triage projekte])
      expect(tabs.map { |node| node.text.squish.sub(/\s\d+\z/, "") }).to eq(["Für dich", "Läuft", "Triage", "Projekte"])
      expect(tabs.first.at_css(".fp-wl-count").text.to_i).to be >= 5
      groups = page.css("#fp-wl-panel-fuer_dich [data-fp-wl-group]").map { |node| node["data-fp-wl-group"] }
      expect(groups).to eq(%w[question for_you human])
      expect(page.css("[data-fp-wl-panel]:not([hidden])").map { |node| node["data-fp-wl-panel"] }).to eq(["fuer_dich"])
    end

    it "shows four rows per group and keeps the rest for „alle N“" do
      rows = page.css("#fp-wl-panel-fuer_dich [data-fp-wl-group='question'] [data-fp-worklist-row]")
      expect(rows.size).to eq(5)
      expect(rows.count { |row| row.key?("hidden") }).to eq(1)
      expect(page.at_css("[data-fp-wl-group='question'] [data-fp-wl-all]").text).to include("alle 5")
    end

    it "renders a row with chat data and a link to the workplace, and escapes the title" do
      row = page.at_css("#fp-wl-panel-laeuft [data-fp-worklist-row][data-id='#{running.id}']")
      expect(row).to be_present
      expect(row["data-subject"]).to eq("<b>Laeuft</b> & mehr")
      expect(row["data-status"]).to eq("In Arbeit")
      expect(row.at_css("a.fp-wl-id")["href"]).to end_with("/flightplan/work_packages/#{running.id}")
      expect(row.at_css("b")).to be_nil
      expect(page.css("#fp-wl-panel-laeuft [data-fp-wl-group='done'][data-collapsed]").size).to eq(1)
    end

    it "lists projects with open tickets in the tab „Projekte“" do
      project_row = page.at_css("#fp-wl-panel-projekte [data-fp-wl-pick-project='liste-fabrik']")
      expect(project_row.text).to include("Liste Fabrik", "6 offen")
    end

    it "serves the work list logic with the stored choice and the fp:thread back channel" do
      get "/flightplan/assets/flightplan.js"
      expect(response.body).to include("function fpWorklist(main)", '"fp-home-left"', "fp:card-selected",
                                       'data.type === "fp:thread"', "fp:chat-active", "fp:chat-next")
    end

    # OP#1835: Abschnitt „Braucht dich“ oben in der Arbeitsliste. Der Server liefert die offenen Rückfragen; die anderen
    # Arten (Freigabe, Fehler, Eingabe) kommen im Browser aus fp:activity.
    describe "section „Braucht dich“" do
      let(:agent) { create(:user, firstname: "Coda", lastname: "Agentin", login: "coda-inbox") }
      let(:inbox) { page.at_css("#fp-inbox") }

      def ask(work_package, text, options: [], created_at: 1.hour.ago, status: "open")
        Flightplan::Question.create!(work_package:, author: agent, question: text, options:, status:, created_at:)
      end

      let!(:newer) { ask(waiting[0], "Welcher Port <b>soll</b> es sein?", options: %w[8093 8094], created_at: 1.hour.ago) }
      let!(:older) { ask(waiting[1], "Darf ich mergen?", created_at: 2.days.ago) }
      let!(:answered) { ask(waiting[2], "Schon erledigt?", status: "answered") }

      before { get "/" }

      it "is the first element of the work list, above the tabs" do
        children = page.at_css("#fp-worklist").element_children
        expect(children.first["id"]).to eq("fp-inbox")
        expect(children[1]["class"]).to include("fp-wl-tabs")
      end

      it "lists exactly the open questions, oldest first, with question, options and answer buttons in the row" do
        rows = inbox.css("[data-fp-inbox-row]")
        expect(rows.map { |row| row["data-id"].to_i }).to eq([waiting[1].id, waiting[0].id])
        expect(rows.map { |row| row["data-kind"] }.uniq).to eq(["question"])
        row = rows.last
        expect(row.at_css(".fp-q-text").text).to eq("Welcher Port <b>soll</b> es sein?")
        expect(row.at_css(".fp-q-text b")).to be_nil
        expect(row.css("button.fp-q-option").map { |button| button["value"] }).to eq(%w[8093 8094])
        form = row.at_css("form[data-fp-question-form]")
        expect(form["action"]).to eq("/flightplan/questions/#{newer.id}/answer")
        expect(row["data-fp-question"]).to eq(newer.id.to_s)
      end

      it "leaves out mirrored „Wartet auf Mensch“ tickets without an open question and answered questions" do
        ids = inbox.css("[data-fp-inbox-row]").map { |row| row["data-id"].to_i }
        expect(ids).not_to include(waiting[2].id, waiting[3].id, waiting[4].id, running.id)
        expect(inbox.at_css("[data-fp-inbox-total]").text).to eq("2")
        expect(inbox.at_css("[data-fp-inbox-empty]")).to have_attributes(name: "p")
        expect(inbox.at_css("[data-fp-inbox-empty]").key?("hidden")).to be(true)
      end

      it "shows the count in the view bar and does not limit the rows to four" do
        3.times { |index| ask(waiting[2], "Weitere Frage #{index}", created_at: (index + 3).hours.ago) }
        get "/"
        rows = inbox.css("[data-fp-inbox-row]")
        expect(rows.size).to eq(5)
        expect(rows.count { |row| row.key?("hidden") }).to eq(0)
        counter = page.at_css("[data-fp-viewbar] [data-fp-inbox-count]")
        expect(counter.text.squish).to eq("Braucht dich (5)")
        expect(counter.key?("hidden")).to be(false)
      end

      it "hides the counter and shows the empty text when nothing needs the user" do
        Flightplan::Question.delete_all
        get "/"
        expect(page.at_css("[data-fp-inbox-count]").key?("hidden")).to be(true)
        expect(page.at_css("[data-fp-inbox-empty]").key?("hidden")).to be(false)
        expect(page.css("[data-fp-inbox-row]")).to be_empty
      end

      it "keeps text field ids unique although „Aufmerksamkeit“ shows the same question" do
        ids = page.css("textarea[id]").map { |node| node["id"] }
        expect(ids).to eq(ids.uniq)
      end

      it "ships labels for the run states and the keyboard logic of the section" do
        labels = JSON.parse(page.at_css("#fp-home")["data-fp-run-labels"])
        expect(labels).to eq("working" => "Agent arbeitet", "approval" => "Freigabe nötig", "input" => "Eingabe nötig",
                             "error" => "Lauf fehlgeschlagen")
        get "/flightplan/assets/flightplan.js"
        expect(response.body).to include("function fpParseActivity(data)", "function fpInbox(main)", "fp:run-states",
                                         "/^[1-9]$/.test(key)", "function fpRunPills()")
      end
    end

    describe "ordering and filter rules of the section (service)" do
      def entry(id, since, text = "Frage")
        { id:, since: Time.zone.at(since), text: }
      end

      it "sorts by age, oldest first, and drops rows without a question text" do
        rows = [entry(3, 300), entry(1, 100), entry(2, 100), entry(9, 50, "")]
        expect(Flightplan::Worklist.inbox_questions(rows).map { |row| row[:id] }).to eq([1, 2, 3])
        expect(Flightplan::Worklist.inbox_count(rows)).to eq(3)
        expect(Flightplan::Worklist.inbox_questions(nil)).to eq([])
      end

      it "ranks approval before question before result (OP#1839) before failure before input and is not limited by SHOWN" do
        expect(Flightplan::Worklist::INBOX_KINDS).to eq(%w[approval question result error input])
        expect(Flightplan::Worklist::RUN_STATES).to eq(%w[working approval input error])
        rows = Array.new(Flightplan::Worklist::SHOWN + 3) { |index| entry(index, index) }
        expect(Flightplan::Worklist.inbox_questions(rows).size).to eq(rows.size)
      end
    end
  end

  describe "as a user without admin rights" do
    current_user { member }

    it "has no work list and no view switch" do
      get "/"
      expect(response.body).not_to include("data-fp-worklist", "data-fp-left-views")
    end
  end
end
