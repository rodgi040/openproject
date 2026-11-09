# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"
require "tmpdir"

# OP#1674: Das Kanban-Board der Seite „Flightplan“ (/flightplan/board) wird ein Insel-Widget im ADA-Dashboard (Startseite /).
# Dazu die Anzeige-Punkte aus Stufe 1 des Konzils zu OP#1670 (B1–B8): keine Wiki-Leiste in den Filtern, Label-Chips nach
# Familie, ODER innerhalb und UND zwischen Familien, Badges für Typ und Priorität, keine Status-Chips, Spalte „Du setzt um“,
# Badge „Weg fehlt“ und der Bereich überall aus der Projekt-Hierarchie.
RSpec.describe "Flightplan board widget", :skip_csrf, type: :rails_request do
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

  let!(:bug_type) { Type.find_by(name: "Bug") || create(:type, name: "Bug") }
  let!(:task_type) { Type.find_by(name: "Aufgabe") || create(:type, name: "Aufgabe") }
  let!(:phase_type) { create(:type, name: "Phase") }
  let!(:wave_type) { create(:type, name: "Welle") }
  let!(:roof_type) { create(:type, name: "Dach") }
  let(:types) { [bug_type, task_type, phase_type, wave_type, roof_type] }

  let!(:niedrig) { create(:priority, name: "Niedrig") }
  let!(:normal) { create(:priority, name: "Normal", is_default: true) }
  let!(:hoch) { create(:priority, name: "Hoch") }
  let!(:sofort) { create(:priority, name: "Sofort") }

  let!(:ada) { create(:project, name: "Board ADA MAIN", identifier: "ada-main", public: false, types:) }
  let!(:flight) { create(:project, name: "Board Flightplan", identifier: "board-flightplan", parent: ada, public: false, types:) }
  let!(:factory) do
    create(:project, name: "Board Fabrik", identifier: "board-fabrik", parent: flight, public: false, types:,
                     enabled_module_names: %w[work_package_tracking wiki])
  end
  let!(:nuova) { create(:project, name: "Board Nuova", identifier: "nuova-ai-solutions", public: false, types:) }
  let!(:agentur) { create(:project, name: "Board Agentur", identifier: "board-agentur", parent: nuova, public: false, types:) }
  let!(:gen) { create(:project, name: "Board Gen", identifier: "nuovagen", public: false, types:) }
  let!(:studio) do
    create(:project, name: "Board Studio", identifier: "board-studio", parent: gen, public: false, types:,
                     enabled_module_names: %w[work_package_tracking])
  end
  let!(:solo) { create(:project, name: "Board Solo", identifier: "board-solo", public: false, types:) }
  let(:all_projects) { [ada, flight, factory, nuova, agentur, gen, studio, solo] }

  let(:admin) { create(:admin, language: "de") }
  let(:agent) { create(:user, firstname: "Coda", lastname: "Agentin", login: "coda") }
  let!(:coding) { create(:group, lastname: "Agenten Coding", members: [agent]) }

  let!(:neu) { ensure_status("Neu") }
  let!(:geplant) { ensure_status("Geplant") }
  let!(:startfreigabe) { ensure_status("Startfreigabe") }
  let!(:in_arbeit) { ensure_status("In Arbeit") }
  let!(:waiting) { ensure_status("Wartet auf Mensch") }
  let!(:review) { ensure_status("Review") }
  let!(:fertig) { ensure_status("Fertig", closed: true) }
  let!(:abgelehnt) { ensure_status("Abgelehnt", closed: true) }

  let(:label_names) do
    %w[needs-triage geplant ready-for-human ready-for-agent-claude bug enhancement idea blocked-on-human question fp:phase
       fp:wave wayfinder:task wayfinder:map claude codex P1 documentation plat:tiktok audit-2026-08]
  end
  let!(:labels_field) do
    create(:multi_list_wp_custom_field, name: "Labels", possible_values: label_names, projects: all_projects)
  end
  let!(:path_field) do
    create(:list_wp_custom_field, name: "Ausführungsweg", possible_values: %w[engine claude codex], projects: all_projects)
  end

  def wp(subject, project:, status:, type: task_type, priority: normal, labels: [], **attrs)
    create(:work_package, project:, status:, type:, priority:, subject:, author: admin, **attrs).tap do |work_package|
      labels.each do |name|
        option = labels_field.custom_options.find_by!(value: name)
        CustomValue.create!(customized: work_package, custom_field: labels_field, value: option.id.to_s)
      end
    end
  end

  let!(:bug_wp) { wp("Fabrik Bug", project: factory, status: neu, type: bug_type, labels: %w[bug needs-triage wayfinder:task]) }
  let!(:high_wp) { wp("Fabrik Hoch", project: factory, status: neu, priority: hoch, labels: %w[enhancement needs-triage P1]) }
  let!(:low_wp) { wp("Fabrik Niedrig", project: factory, status: neu, priority: niedrig, labels: %w[idea]) }
  let!(:wave_wp) { wp("Fabrik Welle", project: factory, status: neu, type: wave_type, labels: %w[fp:wave]) }
  let!(:human_wp) { wp("Fabrik Mensch", project: factory, status: neu, labels: %w[ready-for-human documentation]) }
  let!(:studio_human_wp) { wp("Studio Mensch", project: studio, status: neu, labels: %w[ready-for-human]) }
  let!(:plan_wp) { wp("Fabrik Geplant", project: factory, status: geplant, labels: %w[geplant claude]) }
  let!(:start_nopath_wp) { wp("Fabrik Start ohne Weg", project: factory, status: startfreigabe, labels: %w[wayfinder:task]) }
  let!(:start_label_wp) do
    wp("Fabrik Start mit Label", project: factory, status: startfreigabe, labels: %w[ready-for-agent-claude])
  end
  let!(:start_path_wp) { wp("Agentur Start mit Weg", project: agentur, status: startfreigabe) }
  let!(:phase_wp) do
    wp("Flug Phase", project: flight, status: in_arbeit, type: phase_type, labels: %w[fp:phase P1 wayfinder:task])
  end
  let!(:roof_wp) { wp("Ada Dach", project: ada, status: neu, type: roof_type, labels: %w[wayfinder:map]) }
  let!(:wait_wp) { wp("Studio wartet", project: studio, status: waiting, labels: %w[blocked-on-human codex]) }
  let!(:review_wp) { wp("Solo Review", project: solo, status: review, labels: %w[plat:tiktok]) }
  let!(:done_wp) { wp("Fabrik fertig", project: factory, status: fertig, labels: %w[audit-2026-08]) }
  let!(:rejected_wp) { wp("Fabrik abgelehnt", project: factory, status: abgelehnt) }

  before do
    Rails.cache.clear
    ENV["FP_EXPORT_DIR"] = export_dir
    # Das Projektattribut widerspricht der Hierarchie: es zählt nicht mehr (B8).
    option = bereich_field.custom_options.find_by!(value: "NuovaGen")
    CustomValue.create!(customized: factory, custom_field: bereich_field, value: option.id.to_s)
    claude = path_field.custom_options.find_by!(value: "claude")
    CustomValue.create!(customized: start_path_wp, custom_field: path_field, value: claude.id.to_s)
    high_wp.update_columns(updated_at: 5.days.ago)
    low_wp.update_columns(updated_at: 1.minute.from_now)
  end

  after do
    ENV.delete("FP_EXPORT_DIR")
    FileUtils.remove_entry(export_dir)
    Rails.cache.clear
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def widget(key = "board")
    found = page.at_css("#fp-home .fp-home-main .fp-widgets > .fp-widget[data-fp-widget='#{key}']")
    expect(found).to be_present, "Widget #{key} fehlt"
    found
  end

  def column(key)
    found = widget.at_css("#fp-board section.fp-column[data-column='#{key}']")
    expect(found).to be_present, "Spalte #{key} fehlt"
    found
  end

  def card(work_package)
    widget.at_css("#fp-board [data-fp-board-card][data-id='#{work_package.id}']")
  end

  def subjects(key)
    column(key).css("[data-fp-board-card] .fp-card-title").map { |node| node.text.strip }
  end

  def chip_names(node)
    node.css(".fp-card-labels [data-fp-label-pick]").map { |chip| chip["data-fp-label-pick"] }
  end

  def filter_groups
    widget.css("[data-fp-widget-tools] [data-fp-filter='labels'] fieldset[data-fp-label-group]").map do |group|
      [group.at_css("legend")&.text&.strip, group.css("input[type='checkbox']").map { |box| box["value"] }]
    end
  end

  def board(params = {})
    Flightplan::Board.load(user: admin, params:)
  end

  describe "as admin" do
    current_user { admin }

    %w[/].each do |path|
      it "shows the board as a wide widget after the status bar, with columns, search and filter (A, #{path})" do
        get path
        expect(response).to have_http_status(:ok)
        keys = page.css("#fp-home .fp-home-main .fp-widgets > .fp-widget").map { |node| node["data-fp-widget"] }
        expect(keys).to eq(%w[overview board attention])
        expect(widget["class"]).to include("fp-widget--wide")
        expect(page.at_css("#content-body > #fp-home")).to be_present

        board_node = widget.at_css("#fp-board")
        expect(board_node["data-move-url"]).to eq("/flightplan/board/move")
        expect(board_node["data-csrf"]).to be_present
        keys = board_node.css("section.fp-column").map { |node| node["data-column"] }
        expect(keys).to eq(%w[triage human question for_you agent_ready in_progress review done])
        expect(column("human").at_css(".fp-column-head strong").text).to eq("Du setzt um")
        expect(column("for_you").at_css(".fp-column-head strong").text).to eq("Freigabe entscheiden")
        expect(column("human")["data-drop"]).to eq("off")
        expect(board_node.css("section.fp-column[data-fp-group]").size).to eq(8)

        tools = widget.at_css("[data-fp-widget-tools]")
        expect(tools.at_css("input[type='search'][data-fp-filter='text']")).to be_present
        expect(tools.at_css("select[data-fp-filter='scope'] option[value='project:board-fabrik']")).to be_present
        expect(tools.at_css("select[data-fp-filter-attr='agents'] option[value='coding']")).to be_present
        expect(widget.at_css("[data-fp-widget-toggle][aria-expanded='true']")).to be_present

        node = card(bug_wp)
        expect(node["data-fp-item"]).not_to be_nil
        expect(node["data-fp-area"]).to eq("ADA MAIN")
        expect(JSON.parse(node["data-fp-projects"])).to eq(%w[board-fabrik board-flightplan ada-main])
        expect(node["draggable"]).to eq("true")
        expect(node.at_css("a[href='/flightplan/work_packages/#{bug_wp.id}']")).to be_present
        expect(card(done_wp)["data-fp-open"]).to eq("0")
      end
    end

    it "leaves the old Flightplan page and its menu entry for the dashboard (A)" do
      get "/flightplan"
      expect(response).to redirect_to("/#fp-widget-board")

      get "/flightplan/board", params: { projects: "board-fabrik", labels: "P1" }
      expect(response).to redirect_to("/?#{{ board: { labels: 'P1', projects: 'board-fabrik' } }.to_query}#fp-widget-board")

      names = Redmine::MenuManager.items(:global_menu).map { |item| item.name.to_s }
      expect(names).not_to include("flightplan")
      expect(names).not_to include("flightplan_dashboard") # OP#1721
      get "/"
      expect(response.body).not_to include('href="/flightplan/board', 'href="/flightplan"')
    end

    it "keeps a server-side preselection from the old links and offers to drop it (A)" do
      get "/", params: { board: { projects: "board-fabrik" } }
      expect(widget.css("[data-fp-board-card]").map { |node| node["data-project"] }.uniq).to eq(["board-fabrik"])
      expect(widget.at_css("select[data-fp-filter='scope'] option[selected]")["value"]).to eq("project:board-fabrik")
      reset = widget.at_css("a[data-fp-board-preset-reset]")
      expect(reset["href"]).to eq("/#fp-widget-board")
    end

    it "moves a card through the move route and tells the new column (A)" do
      role = create(:project_role)
      [[neu, geplant], [geplant, neu]].each do |from, to|
        [bug_type, task_type].each { |type| create(:workflow, type:, role:, old_status: from, new_status: to) }
      end
      post "/flightplan/board/move", params: { id: bug_wp.id, column: "for_you", lock_version: bug_wp.lock_version }
      expect(response).to have_http_status(:ok), response.body
      payload = JSON.parse(response.body)
      expect(payload).to include("ok" => true, "column" => "for_you", "lock_version" => bug_wp.reload.lock_version)
      expect(bug_wp.status).to eq(geplant)

      post "/flightplan/board/move", params: { id: plan_wp.id, column: "human", lock_version: plan_wp.lock_version }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("ready-for-human")
      expect(plan_wp.reload.status).to eq(geplant)
    end

    it "shows no wiki chip without a project and a labelled wiki link for exactly one project with wiki (B1)" do
      get "/"
      expect(widget.css("[data-wiki]")).to be_empty
      expect(widget.css("[data-fp-widget-tools] a[href*='/wiki']")).to be_empty
      link = widget.at_css("a[data-fp-board-wiki]")
      expect(link["hidden"]).not_to be_nil
      wikis = JSON.parse(widget.at_css("script[data-fp-board-wikis]").text)
      expect(wikis.keys).to include("board-fabrik")
      expect(wikis.keys).not_to include("board-studio")
      expect(wikis["board-fabrik"]["label"]).to eq("Wiki von Board Fabrik")

      get "/", params: { board: { projects: "board-fabrik" } }
      link = widget.at_css("a[data-fp-board-wiki]")
      expect(link["hidden"]).to be_nil
      expect(link.text.strip).to eq("Wiki von Board Fabrik")
      expect(link["href"]).to start_with("/projects/board-fabrik/wiki")

      get "/", params: { board: { projects: "board-studio" } }
      expect(widget.at_css("a[data-fp-board-wiki]")["hidden"]).not_to be_nil

      get "/", params: { board: { projects: "board-fabrik,board-studio" } }
      expect(widget.at_css("a[data-fp-board-wiki]")["hidden"]).not_to be_nil
    end

    it "groups the label chips by family with a heading, only for open packages and without status, waiting and kind (B2)" do
      expect(OpenProject::Flightplan::Engine.root.join("config/label_families.yml")).to be_file
      expect(Flightplan::LabelFamilies.family_for("wayfinder:task")).to include(key: "wayfinder", title: "Wayfinder")
      expect(Flightplan::LabelFamilies.family_for("needs-triage")).to include(key: "status")
      expect(Flightplan::LabelFamilies.family_for("blocked-on-human")).to include(key: "warten")
      expect(Flightplan::LabelFamilies.family_for("bug")).to include(key: "art")
      expect(Flightplan::LabelFamilies.family_for("plat:tiktok")).to include(key: "projekt")
      expect(Flightplan::LabelFamilies.family_for("ganz-neu")).to include(key: "projekt", title: "Projekt-spezifisch")

      get "/"
      groups = filter_groups
      expect(groups).to all(satisfy { |title, _| title.present? })
      names = groups.flat_map(&:last)
      expect(names).not_to include("needs-triage", "geplant", "ready-for-human", "ready-for-agent-claude", "bug",
                                   "enhancement", "idea", "blocked-on-human", "question")
      expect(names).not_to include("audit-2026-08")
      expect(groups.to_h).to include("Wayfinder" => %w[wayfinder:map wayfinder:task], "Agent" => %w[claude codex],
                                     "Plan-Typ" => %w[fp:phase fp:wave], "Priorität" => %w[P1])
      expect(widget.css("[data-fp-filter='labels'] legend").map(&:text).map(&:strip))
        .to eq(%w[Plan-Typ Wayfinder Agent Priorität Thema Projekt-spezifisch])

      get "/", params: { board: { projects: "board-fabrik" } }
      names = filter_groups.flat_map(&:last)
      expect(names.size).to be <= 15
      expect(names).to contain_exactly("wayfinder:task", "claude", "P1", "fp:wave", "documentation")
    end

    it "combines labels with OR inside a family and AND across families, on the board and in the widget filters (B3)" do
      across = board(labels: "wayfinder:task,P1").columns.flat_map(&:cards).map(&:id)
      expect(across).to contain_exactly(phase_wp.id)
      inside = board(labels: "wayfinder:task,wayfinder:map").columns.flat_map(&:cards).map(&:id)
      expect(inside).to contain_exactly(bug_wp.id, start_nopath_wp.id, phase_wp.id, roof_wp.id)

      get "/", params: { board: { labels: "wayfinder:task,P1" } }
      expect(widget.css("[data-fp-board-card]").map { |node| node["data-id"].to_i }).to eq([phase_wp.id])

      expect(Flightplan::WidgetFilters.label_groups(%w[P1 wayfinder:task bug wayfinder:map]))
        .to eq([{ key: "wayfinder", title: "Wayfinder", names: %w[wayfinder:map wayfinder:task] },
                { key: "prioritaet", title: "Priorität", names: %w[P1] }])
      get "/"
      attention = widget("attention").css("[data-fp-filter='labels'] fieldset[data-fp-label-group]")
      expect(attention.map { |group| group.at_css("legend")&.text&.strip }).to all(be_present)
      get "/flightplan/assets/flightplan.js"
      expect(response.body).to include("selected().every(", "names.some(")
    end

    it "shows type and priority badges and sorts each column by priority before the last change (B4)" do
      get "/"
      expect(card(bug_wp).at_css("[data-fp-type='Bug']").text.strip).to eq("Bug")
      expect(card(high_wp).at_css("[data-fp-type='Aufgabe']")).to be_present
      expect(card(wave_wp).at_css("[data-fp-type='Welle']")).to be_present
      expect(card(phase_wp).at_css("[data-fp-type='Phase']")).to be_present
      expect(card(roof_wp).at_css("[data-fp-type='Dach']")).to be_present
      widget.css("[data-fp-board-card]").each do |node|
        expect(node.at_css("[data-fp-type]")).to be_present, node["data-id"]
      end

      expect(card(high_wp).at_css("[data-fp-priority='Hoch']").text.strip).to eq("Hoch")
      expect(card(low_wp).at_css("[data-fp-priority='Niedrig']")).to be_present
      expect(card(bug_wp).at_css("[data-fp-priority]")).to be_nil
      triage = subjects("triage")
      expect(triage.first).to eq("Fabrik Hoch")
      expect(triage.last).to eq("Fabrik Niedrig")
      expect(triage.index("Fabrik Hoch")).to be < triage.index("Fabrik Bug")
    end

    it "shows no status chip on a card and no chip that repeats the column or the type; the data stays (B5)" do
      get "/"
      widget.css("[data-fp-board-card]").each do |node|
        expect(chip_names(node)).not_to include("needs-triage", "geplant", "ready-for-human", "ready-for-agent-claude")
      end
      expect(chip_names(card(bug_wp))).to eq(["wayfinder:task"])
      expect(chip_names(card(high_wp))).to eq(["P1"])
      expect(chip_names(card(phase_wp))).to contain_exactly("P1", "wayfinder:task")
      expect(chip_names(card(wave_wp))).to be_empty
      expect(chip_names(card(human_wp))).to eq(["documentation"])
      expect(chip_names(card(wait_wp))).to eq(["codex"])
      expect(JSON.parse(card(bug_wp)["data-fp-labels"])).to include("needs-triage", "bug", "wayfinder:task")
      expect(card(bug_wp).at_css("[data-fp-label-pick]").name).to eq("button")
    end

    it "puts Neu with ready-for-human into its own column and keeps the total (B6)" do
      get "/"
      expect(subjects("human")).to contain_exactly("Fabrik Mensch", "Studio Mensch")
      expect(subjects("triage")).not_to include("Fabrik Mensch", "Studio Mensch")
      counts = widget.css("#fp-board section.fp-column").to_h { |node| [node["data-column"], node["data-count"].to_i] }
      neu_total = WorkPackage.where(status: neu).count
      expect(counts["triage"]).to eq(neu_total - 2)
      expect(counts["human"]).to eq(2)
      expect(counts["for_you"]).to eq(1)
      shown = WorkPackage.where.not(status: abgelehnt).count
      expect(counts.values.sum).to eq(shown)
    end

    it "marks Startfreigabe without a path and without an agent label as „Weg fehlt“, also in the attention (B7)" do
      get "/"
      expect(card(start_nopath_wp).at_css("[data-fp-badge='no-path']").text.strip).to eq("Weg fehlt")
      [start_label_wp, start_path_wp, plan_wp, bug_wp].each do |work_package|
        expect(card(work_package).at_css("[data-fp-badge='no-path']")).to be_nil, work_package.subject
      end
      reasons = ->(work_package) { widget("attention").css("tr[data-wp='#{work_package.id}'] [data-reason]").map { |node| node["data-reason"] } }
      expect(reasons.(start_nopath_wp)).to include("no_path")
      expect(reasons.(start_label_wp)).not_to include("no_path")
      expect(reasons.(start_path_wp)).not_to include("no_path")
      expect(Flightplan::LabelFamilies.agent_label?("claude")).to be(true)
      expect(Flightplan::LabelFamilies.agent_label?("ready-for-agent-codex")).to be(true)
      expect(Flightplan::LabelFamilies.agent_label?("ready-for-agent")).to be(false)
    end

    it "takes the Bereich from the project hierarchy on the board and in the dashboard, with the same numbers (B8)" do
      get "/"
      tiles = widget("overview").css("[data-bereich-tile]").to_h do |tile|
        [tile["data-bereich-tile"], tile.at_css("[data-stat='open'] .fp-dash-num").text.strip.to_i]
      end
      chips = widget.css("[data-fp-board-bereich]").to_h { |node| [node["data-fp-board-bereich"], node["data-open"].to_i] }
      expect(chips).to eq(tiles)
      expect(tiles).to eq("ADA MAIN" => 10, "Nuova AI Solutions" => 1, "NuovaGen" => 2, "Ohne Bereich" => 1)

      solo_tile = widget("overview").at_css("[data-bereich-tile='Ohne Bereich']")
      expect(solo_tile.css("[data-fp-item] a").map(&:text).map(&:strip)).to eq(["Board Solo"])
      expect(card(bug_wp)["data-fp-area"]).to eq("ADA MAIN")
      expect(card(studio_human_wp)["data-fp-area"]).to eq("NuovaGen")
      expect(card(review_wp)["data-fp-area"]).to eq("Ohne Bereich")
      expect(widget("attention").at_css("tr[data-wp='#{start_nopath_wp.id}']")["data-fp-area"]).to eq("ADA MAIN")

      expect(board(bereich: "ada-main").columns.sum(&:count)).to eq(board.columns.sum { |col| col.cards.count { |c| c.bereich == "ADA MAIN" } })
      expect(board(bereich: "ohne").columns.flat_map(&:cards).map(&:id)).to eq([review_wp.id])
    end
  end

  describe "as a member without admin rights" do
    let(:role) { create(:project_role, permissions: %i[view_work_packages]) }
    let(:member) { create(:user, language: "de", member_with_roles: { factory => role }) }

    current_user { member }

    it "shows the board widget with the visible packages next to the questions" do
      get "/"
      expect(response).to have_http_status(:ok)
      keys = page.css(".fp-widgets > .fp-widget").map { |node| node["data-fp-widget"] }
      expect(keys).to eq(%w[questions board])
      ids = widget.css("[data-fp-board-card]").map { |node| node["data-project"] }.uniq
      expect(ids).to eq(["board-fabrik"])
      expect(response.body).not_to include("Studio Mensch", "Solo Review")
    end
  end
end
