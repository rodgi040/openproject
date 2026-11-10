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
  end

  describe "as a user without admin rights" do
    current_user { member }

    it "has no work list and no view switch" do
      get "/"
      expect(response.body).not_to include("data-fp-worklist", "data-fp-left-views")
    end
  end
end
