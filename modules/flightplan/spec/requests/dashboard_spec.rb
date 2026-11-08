# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"
require "tmpdir"

RSpec.describe "Flightplan dashboard", :skip_csrf, type: :rails_request do
  def ensure_status(name, closed: false)
    status = Status.find_by(name:) || create(:status, name:, is_closed: closed)
    status.update!(is_closed: closed) if status.is_closed? != closed
    status
  end

  # Zeit im Status zählt aus den Journalen; updated_at zieht mit, damit die Regel "ohne Änderung" greift.
  def backdate(work_package, time)
    work_package.journals.update_all(created_at: time, updated_at: time)
    work_package.update_columns(updated_at: time)
  end

  let(:export_dir) { Dir.mktmpdir("fp-export") }
  let(:section) { create(:project_custom_field_section) }
  let!(:bereich_field) do
    create(:list_project_custom_field, name: "Bereich", project_custom_field_section: section,
                                       possible_values: ["ADA MAIN", "Nuova AI Solutions", "NuovaGen"])
  end
  # OP#1674: Der Bereich kommt aus der Projekt-Hierarchie; die Wurzeln tragen die Bereichs-Identifier.
  let!(:ada) { create(:project, name: "Dash Ada", identifier: "ada-main", public: false) }
  let!(:agentur) { create(:project, name: "Dash Agentur", identifier: "nuova-ai-solutions", public: false) }
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
    backdate(stale_wp, 9.days.ago)
    backdate(fresh_wp, 2.days.ago)
    backdate(waiting_wp, 3.days.ago)
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
      # OP#1674: Startfreigabe ohne Ausführungsweg und ohne Agent-Label trägt den Grund „Weg fehlt“, sonst kein Grund.
      expect(ada_table.scan(/data-reason="([a-z_]+)"/).flatten).to eq(["no_path"])
      expect(response.body).to include('data-bereich-table="Ohne Bereich"')
      expect(response.body).not_to include('data-bereich-table="NuovaGen"')
    end

    it "links every row to the Arbeitsplatz page and shows the age" do
      get "/flightplan/dashboard"
      expect(response.body).to include(%(href="/flightplan/work_packages/#{waiting_wp.id}"))
      row = response.body[/<tr data-wp="#{stale_wp.id}"[^>]*>.*?<\/tr>/m]
      expect(row).to include("9 T")
    end

    it "sorts each group by age, oldest first" do
      get "/flightplan/dashboard"
      table = response.body[/data-bereich-table="ADA MAIN">.*?<\/table>/m]
      expect(table.index("Wartet Eins")).to be < table.index("Start Drei")
    end

    it "filters by Bereich" do
      get "/flightplan/dashboard", params: { bereich: "nuova-ai-solutions" }
      attention = response.body[/id="fp-widget-attention".*?<\/section>/m]
      expect(attention).to include("Frage Zwei")
      expect(attention).not_to include("Wartet Eins")
      get "/flightplan/dashboard", params: { bereich: "nuovagen" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("fp-dash-empty")
    end

    it "names the Bereich in the empty state" do
      get "/flightplan/dashboard", params: { bereich: "nuovagen" }
      expect(response.body[/id="fp-dash-empty">(.*?)<\/p>/m, 1]).to eq("Nichts offen in NuovaGen")
      expect(response.body).not_to include("fp-unknown-bereich")
    end

    it "wraps the attention table in a scroll container for narrow screens" do
      get "/flightplan/dashboard"
      expect(response.body).to match(/<div class="fp-dash-scroll">\s*<table class="fp-dash-table"/)
      css = File.read(File.expand_path("../../app/assets/flightplan/flightplan.css", __dir__))
      expect(css[/\.fp-dash-scroll \{[^}]*\}/m]).to include("overflow-x: auto")
      expect(response.body).not_to match(/<div class="fp-dash-scroll"[^>]*style=/)
    end

    it "hints at an unknown Bereich key, escaped, and shows all areas" do
      get "/flightplan/dashboard", params: { bereich: "<b>x</b>'" }
      expect(response).to have_http_status(:ok)
      hint = response.body[/id="fp-unknown-bereich"[^>]*>(.*?)<\/p>/m, 1]
      expect(hint).to include("Unbekannter Bereich „")
      expect(hint).to include("alle Bereiche gezeigt")
      expect(hint).to include("&lt;b&gt;x&lt;/b&gt;")
      expect(response.body).not_to include("<b>x</b>")
      expect(response.body).to include("Wartet Eins")
    end

    it "escapes ticket titles" do
      get "/flightplan/dashboard"
      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    end

    it "shows projects, open, blocked, questions and agents per Bereich, with links" do
      get "/flightplan/dashboard"
      tile = response.body[/data-bereich-tile="ADA MAIN">.*?<\/article>/m]
      expect(tile).to include("Dash Ada")
      expect(tile).to match(%r{data-stat="projects".*?fp-dash-num">.*?>1</a>}m)
      expect(tile).to match(%r{data-stat="open".*?>4</a>}m)
      expect(tile).to match(%r{data-stat="blocked".*?>1</a>}m)
      expect(tile).to match(%r{data-stat="questions".*?>0</a>}m)
      expect(tile).to match(%r{data-stat="agents".*?nicht aktiv}m)
      expect(tile).to include('href="/flightplan/dashboard?board%5Bbereich%5D=ada-main#fp-widget-board"')
      expect(tile).to include('href="/flightplan/dashboard?bereich=ada-main#fp-dash-attention-title"')
      other = response.body[/data-bereich-tile="Nuova AI Solutions">.*?<\/article>/m]
      expect(other).to match(%r{data-stat="questions".*?>1</a>}m)
      expect(other).to include("/flightplan/dashboard?rueckfragen=bereich%3ANuova+AI+Solutions")
      expect(response.body[/data-bereich-tile="Ohne Bereich">.*?<\/article>/m]).not_to include("?bereich=", "&amp;bereich=")
    end

    it "counts the age from the last status change, not from updated_at" do
      # Status vor 5 Tagen gewechselt, danach nur ein Kommentar (updated_at ist frisch)
      backdate(waiting_wp, 5.days.ago)
      waiting_wp.update_columns(updated_at: 1.minute.ago)
      get "/flightplan/dashboard"
      row = response.body[/<tr data-wp="#{waiting_wp.id}"[^>]*>.*?<\/tr>/m]
      expect(row).to include("5 T")
    end

    it "uses one query for the status history of all candidates" do
      get "/flightplan/dashboard"
      Rails.cache.clear
      queries = []
      # Nur die Statushistorie der Aufmerksamkeit (previous_status_id); das Board-Widget (OP#1674) fragt „Fertig“ eigens ab.
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("LAG(") && payload[:sql].include?("previous_status_id") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get "/flightplan/dashboard" }
      expect(queries.size).to eq(1)
    end

    describe "failed starts" do
      let!(:dispatcher) { create(:user, login: "dispatcher") }
      let(:alarm) { create(:work_package, project: ada, author: admin, status: waiting, subject: "Alarm Acht") }
      let(:fallback) { create(:work_package, project: ada, author: admin, status: waiting, subject: "Rueckfall Neun") }
      let(:old) { create(:work_package, project: ada, author: admin, status: waiting, subject: "Alt Zehn") }

      def row(id)
        response.body[/data-bereich-table="ADA MAIN">.*?<\/table>/m][/<tr data-wp="#{id}"[^>]*>.*?<\/tr>/m]
      end

      def note(work_package, text, user: dispatcher, at: nil)
        journal = work_package.journals.order(:version).last
        journal.update_columns(notes: text, user_id: user.id, **(at ? { created_at: at } : {}))
      end

      it "marks the poller marker and the dispatch fallback from dispatcher, only within 14 days" do
        loose_wp.journals.destroy_all
        [alarm, fallback, old].each { |wp| backdate(wp, 1.day.ago) }
        note(alarm, "Start nicht bestätigt.\n<!-- fp-op-alarm:start:#{alarm.id} -->")
        note(fallback, "ada-dispatch: Start fehlgeschlagen (boom). Bitte prüfen.")
        note(old, "<!-- fp-op-alarm:start:#{old.id} -->", at: 20.days.ago)
        get "/flightplan/dashboard"
        expect(row(alarm.id)).to include("Start fehlgeschlagen")
        expect(row(fallback.id)).to include("Start fehlgeschlagen")
        expect(row(old.id)).not_to include("fp-dash-reason")
        expect(row(waiting_wp.id)).not_to include("fp-dash-reason")
      end

      it "gives no false alarm for a note from another author" do
        loose_wp.journals.destroy_all
        backdate(alarm, 1.day.ago)
        note(alarm, "<!-- fp-op-alarm:start:#{alarm.id} -->", user: agent)
        get "/flightplan/dashboard"
        expect(row(alarm.id)).not_to include("Start fehlgeschlagen")
      end

      it "gives no false alarm for a note older than the last entry into Wartet auf Mensch" do
        loose_wp.journals.destroy_all
        earlier = create(:work_package, project: ada, author: admin, status: in_arbeit, subject: "Wieder Elf")
        backdate(earlier, 6.days.ago)
        note(earlier, "<!-- fp-op-alarm:start:#{earlier.id} -->")
        User.execute_as(admin) { earlier.reload.update!(status: waiting) }
        expect(earlier.journals.count).to eq(2)
        get "/flightplan/dashboard"
        expect(row(earlier.id)).not_to include("Start fehlgeschlagen")
        expect(row(earlier.id)).to include("Wartet auf Mensch")
      end
    end

    describe "a renamed status" do
      it "warns visibly, caches nothing and reports it for dashboard-check" do
        ensure_status("Geplant")
        startfreigabe.update!(name: "Startfreigabe neu")
        Rails.cache.clear
        get "/flightplan/dashboard"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("data-fp-missing-status=\"Startfreigabe\"", "Status „Startfreigabe“ nicht gefunden")
        expect(Rails.cache.read(Flightplan::Dashboard::STATUS_IDS_CACHE_KEY)).to be_nil
        expect(Rails.cache.read(Flightplan::Dashboard.cache_key(admin.id))).to be_nil
        expect(Flightplan::Dashboard.check_report(user: admin)[:missing_statuses]).to eq(["Startfreigabe"])
        startfreigabe.update!(name: "Startfreigabe")
        get "/flightplan/dashboard"
        expect(response.body).not_to include("data-fp-missing-status")
        expect(Flightplan::Dashboard.check_report(user: admin)[:missing_statuses]).to eq([])
      end
    end

    it "keeps the age column on one line through the stylesheet, not inline" do
      get "/flightplan/dashboard"
      expect(response.body).to include('class="fp-dash-age"')
      expect(response.body).not_to match(/white-space/)
      expect(File.read(File.expand_path("../../app/assets/flightplan/flightplan.css", __dir__)))
        .to match(/\.fp-dash-age\s*\{\s*white-space: nowrap;/)
    end

    it "reports counts for dashboard-check" do
      report = Flightplan::Dashboard.check_report(user: admin)
      expect(report[:statuses]).to include("Wartet auf Mensch" => 2, "Startfreigabe" => 1, "In Arbeit" => 2, "Neu" => 2)
      expect(report[:total_open]).to eq(7)
      expect(report[:tiles]["ADA MAIN"]).to eq(open: 4, blocked: 1)
    end

    it "marks all host sources as not active when the export directory is empty" do
      get "/flightplan/dashboard"
      expect(response).to have_http_status(:ok)
      %w[health engine agents].each do |key|
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
        "slots" => { "belegt" => 2, "maximum" => 4, "frei" => 2 }, "queue" => [1, 2, 3],
        "letzte_starts" => [
          { "op" => fresh_wp.id, "harness" => "claude", "modell" => "opus", "gestartet" => 1.hour.ago.utc.iso8601 },
          { "op" => plain_wp.id, "harness" => "codex" }, { "op" => "x<b>" }, "kaputt"
        ]
      ))
      get "/flightplan/dashboard"
      health = response.body[/data-tile="health">.*?<\/article>/m]
      engine = response.body[/data-tile="engine">.*?<\/article>/m]
      slots = response.body[/data-tile="agents">.*?<\/article>/m]
      expect(health).to include('data-lamp="gelb"', "sync")
      expect(health).not_to include("<b>")
      expect(health).not_to include("nicht aktiv")
      expect(engine).to include("1.2.3", "4.5.6", "veraltet")
      expect(slots).to include(">2</span> /", ">4</span>", "3 in der Warteschlange", "Frisch Fuenf", "claude opus")
      expect(slots).not_to include("Ruhig Sechs", "<b>")
      tile = response.body[/data-bereich-tile="ADA MAIN">.*?<\/article>/m]
      expect(tile).to match(%r{data-stat="agents".*?fp-dash-num">.*?>1</a>}m)
    end

    it "has no external hosts in the page" do
      get "/flightplan/dashboard"
      body = Nokogiri::HTML(response.body).at_css("#fp-dashboard")
      expect(body).to be_present
      expect(body.to_html).not_to match(%r{(src|href)="https?://})
    end

    it "shows a future timestamp as not active" do
      File.write(File.join(export_dir, "snapshot.json"), JSON.generate("erzeugt_am" => 3.days.from_now.utc.iso8601))
      File.write(File.join(export_dir, "status.json"), JSON.generate("heartbeat" => { "epoch" => 10**40 }, "gesamt" => "gruen"))
      get "/flightplan/dashboard"
      expect(response).to have_http_status(:ok)
      expect(response.body[/data-tile="engine">.*?<\/article>/m]).to include("Zeit in der Zukunft")
      expect(response.body[/data-tile="health">.*?<\/article>/m]).to include("Zeit in der Zukunft")
    end

    it "serves the approvals page" do
      get "/flightplan/approvals"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("fp-approvals-empty", "Aufmerksamkeitstabelle")
    end

    it "adds the menu entry ADA Dashboard" do
      get "/flightplan/work_packages/#{plain_wp.id}"
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
      get "/flightplan/work_packages/#{plain_wp.id}"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-name="flightplan"', 'data-name="flightplan_dashboard"')
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
