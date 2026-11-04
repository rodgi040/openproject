# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"
require "tmpdir"

RSpec.describe "Flightplan dashboard", :skip_csrf, type: :rails_request do
  def ensure_status(name, closed: false)
    status = Status.find_by(name:) || create(:status, name:, is_closed: closed)
    status.update!(is_closed: closed) if status.is_closed? != closed
    status
  end

  let(:export_dir) { Dir.mktmpdir("fp-export") }
  let(:section) { create(:project_custom_field_section) }
  let!(:bereich_field) do
    create(:list_project_custom_field, name: "Bereich", project_custom_field_section: section,
                                       possible_values: ["ADA MAIN", "Nuova AI Solutions", "NuovaGen"])
  end
  let!(:ada) { create(:project, name: "Dash Ada", public: false) }
  let!(:agentur) { create(:project, name: "Dash Agentur", public: false) }
  let!(:ohne) { create(:project, name: "Dash Ohne", public: false) }
  let(:admin) { create(:admin, language: "de") }
  let!(:neu) { ensure_status("Neu") }
  let!(:waiting) { ensure_status("Wartet auf Mensch") }
  let!(:startfreigabe) { ensure_status("Startfreigabe") }
  let!(:in_arbeit) { ensure_status("In Arbeit") }
  let!(:fertig) { ensure_status("Fertig", closed: true) }
  let!(:agent) { create(:user, firstname: "Cora", lastname: "Agent") }

  let!(:waiting_wp) { create(:work_package, project: ada, author: admin, status: waiting, subject: "Wartet Eins", assigned_to: agent) }
  let!(:question_wp) { create(:work_package, project: agentur, author: admin, status: neu, subject: "Frage Zwei") }
  let!(:start_wp) { create(:work_package, project: ada, author: admin, status: startfreigabe, subject: "Start Drei") }
  let!(:stale_wp) { create(:work_package, project: agentur, author: admin, status: in_arbeit, subject: "Alt Vier") }
  let!(:fresh_wp) { create(:work_package, project: ada, author: admin, status: in_arbeit, subject: "Frisch Fuenf") }
  let!(:plain_wp) { create(:work_package, project: ada, author: admin, status: neu, subject: "Ruhig Sechs") }
  let!(:closed_wp) { create(:work_package, project: ada, author: admin, status: fertig, subject: "Fertig Sieben") }
  let!(:loose_wp) { create(:work_package, project: ohne, author: admin, status: waiting, subject: "<script>alert(1)</script>") }

  before do
    Rails.cache.clear
    ENV["FP_EXPORT_DIR"] = export_dir
    {
      ada => "ADA MAIN", agentur => "Nuova AI Solutions"
    }.each do |project, label|
      option = bereich_field.custom_options.find_by!(value: label)
      CustomValue.create!(customized: project, custom_field: bereich_field, value: option.id.to_s)
    end
    Flightplan::Question.create!(work_package: question_wp, author: agent, question: "Offene Frage", status: "open")
    Flightplan::Question.create!(work_package: closed_wp, author: agent, question: "Zu spaet", status: "open")
    stale_wp.update_columns(updated_at: 9.days.ago)
    fresh_wp.update_columns(updated_at: 2.days.ago)
    waiting_wp.update_columns(updated_at: 3.days.ago)
  end

  after do
    ENV.delete("FP_EXPORT_DIR")
    FileUtils.remove_entry(export_dir)
    Rails.cache.clear
  end

  describe "as admin" do
    current_user { admin }

    it "lists exactly the packages that need attention, grouped by Bereich" do
      get "/flightplan/dashboard"
      expect(response).to have_http_status(:ok), response.body

      ada_table = response.body[/data-bereich-table="ADA MAIN">.*?<\/table>/m]
      agentur_table = response.body[/data-bereich-table="Nuova AI Solutions">.*?<\/table>/m]
      expect(ada_table).to include("Wartet Eins", "Start Drei", "Cora Agent")
      expect(ada_table).not_to include("Frisch Fuenf", "Ruhig Sechs", "Fertig Sieben")
      expect(agentur_table).to include("Frage Zwei", "Alt Vier", "offene Rückfrage", "ohne Änderung")
      expect(response.body).to include('data-bereich-table="Ohne Bereich"')
      expect(response.body).not_to include('data-bereich-table="NuovaGen"')
    end

    it "links every row to the Arbeitsplatz page and shows the age" do
      get "/flightplan/dashboard"
      expect(response.body).to include(%(href="/flightplan/work_packages/#{waiting_wp.id}"))
      row = response.body[/<tr data-wp="#{stale_wp.id}">.*?<\/tr>/m]
      expect(row).to include("9 T")
    end

    it "sorts each group by age, oldest first" do
      get "/flightplan/dashboard"
      table = response.body[/data-bereich-table="ADA MAIN">.*?<\/table>/m]
      expect(table.index("Wartet Eins")).to be < table.index("Start Drei")
    end

    it "filters by Bereich" do
      get "/flightplan/dashboard", params: { bereich: "nuova-ai-solutions" }
      expect(response.body).to include("Frage Zwei")
      expect(response.body).not_to include("Wartet Eins")
      get "/flightplan/dashboard", params: { bereich: "nuovagen" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("fp-dash-empty")
    end

    it "escapes ticket titles" do
      get "/flightplan/dashboard"
      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    end

    it "counts open and blocked per Bereich in the tiles" do
      get "/flightplan/dashboard"
      tile = response.body[/data-bereich-tile="ADA MAIN">.*?<\/article>/m]
      expect(tile).to include("Dash Ada")
      expect(tile).to match(%r{<span class="fp-dash-num">4</span> offen})
      expect(tile).to match(%r{<span class="fp-dash-num">1</span> blockiert})
    end

    it "marks all host sources as not active when the export directory is empty" do
      get "/flightplan/dashboard"
      expect(response).to have_http_status(:ok)
      %w[health engine slots].each do |key|
        tile = response.body[/data-tile="#{key}">.*?<\/article>/m]
        expect(tile).to include("nicht aktiv")
      end
    end

    it "shows the host sources with their freshness when the files exist" do
      File.write(File.join(export_dir, "status.json"), JSON.generate(
        "gesamt" => "gelb", "heartbeat" => { "epoch" => Time.current.to_i },
        "pruefungen" => [{ "name" => "sync", "ampel" => "gelb" }, { "name" => "x", "ampel" => "<b>" }]
      ))
      File.write(File.join(export_dir, "snapshot.json"), JSON.generate(
        "erzeugt_am" => 20.minutes.ago.utc.iso8601, "gesamt" => "gruen",
        "engine" => { "version" => "1.2.3", "ampel" => "gruen" }, "plugin" => { "version" => "4.5.6", "ampel" => "gelb" }
      ))
      File.write(File.join(export_dir, "dispatch.json"), JSON.generate(
        "slots" => { "belegt" => 2, "maximum" => 4, "frei" => 2 }, "queue" => [1, 2, 3]
      ))
      get "/flightplan/dashboard"
      health = response.body[/data-tile="health">.*?<\/article>/m]
      engine = response.body[/data-tile="engine">.*?<\/article>/m]
      slots = response.body[/data-tile="slots">.*?<\/article>/m]
      expect(health).to include('data-lamp="gelb"', "sync")
      expect(health).not_to include("<b>")
      expect(health).not_to include("nicht aktiv")
      expect(engine).to include("1.2.3", "4.5.6", "veraltet")
      expect(slots).to include(">2</span> /", ">4</span>", "3 in der Warteschlange")
    end

    it "has no external hosts in the page" do
      get "/flightplan/dashboard"
      body = response.body[/<div id="fp-dashboard".*?<\/section>\s*<\/div>/m]
      expect(body).not_to match(%r{(src|href)="https?://})
    end

    it "serves the empty approvals page" do
      get "/flightplan/approvals"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("fp-approvals-empty")
    end

    it "adds the menu entry ADA Dashboard" do
      get "/flightplan/board"
      expect(response.body).to include("ADA Dashboard")
      expect(response.body).to include('data-name="flightplan_dashboard"', "/flightplan/dashboard\"")
    end

    it "changes nothing" do
      expect { get "/flightplan/dashboard" }.not_to change { [WorkPackage.maximum(:updated_at), Journal.count] }
    end
  end

  describe "as a project member without admin rights" do
    let(:role) { create(:project_role, permissions: %i[view_work_packages]) }
    let(:member) { create(:user, language: "de", member_with_roles: { ada => role }) }

    current_user { member }

    it "answers 403 and hides the menu entry" do
      get "/flightplan/dashboard"
      expect(response).to have_http_status(:forbidden)
      get "/flightplan/approvals"
      expect(response).to have_http_status(:forbidden)
      get "/flightplan/board"
      expect(response.body).to include('data-name="flightplan"')
      expect(response.body).not_to include('data-name="flightplan_dashboard"')
    end
  end

  describe "anonymous" do
    current_user { User.anonymous }

    it "does not serve the page" do
      get "/flightplan/dashboard"
      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include("Wartet Eins")
    end
  end
end
