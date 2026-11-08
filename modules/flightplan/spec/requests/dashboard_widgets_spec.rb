# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"
require "tmpdir"

# OP#1672: Das ADA-Dashboard (Startseite / und /flightplan/dashboard) besteht aus Insel-Widgets: Übersicht oben, darunter
# Aufmerksamkeit, laufende Agents und Betrieb. Jedes Widget hat einen eigenen Scrollbereich und Suche und Filter
# (Text, Projekt/Bereich, Status, Label), die im Browser über die gerenderten Einträge wirken.
RSpec.describe "Flightplan dashboard widgets", :skip_csrf, type: :rails_request do
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
  let!(:ada) { create(:project, name: "Widget Ada", identifier: "widget-ada", public: false) }
  let!(:flight) { create(:project, name: "Widget Flug", identifier: "widget-flug", parent: ada, public: false) }
  let!(:factory) { create(:project, name: "Widget Fabrik", identifier: "widget-fabrik", parent: flight, public: false) }
  let!(:gen) { create(:project, name: "Widget Gen", identifier: "widget-gen", public: false) }
  let!(:gen_child) { create(:project, name: "Widget Gen Kind", identifier: "widget-gen-kind", parent: gen, public: false) }
  let(:admin) { create(:admin, language: "de") }
  let!(:neu) { ensure_status("Neu") }
  let!(:waiting) { ensure_status("Wartet auf Mensch") }
  let!(:startfreigabe) { ensure_status("Startfreigabe") }
  let!(:in_arbeit) { ensure_status("In Arbeit") }
  let!(:labels_field) do
    create(:multi_list_wp_custom_field, name: "Labels", possible_values: ["P1", "agent:autonom", "<b>fett</b>"],
                                        projects: [ada, flight, factory, gen, gen_child])
  end

  let!(:waiting_wp) { create(:work_package, project: factory, author: admin, status: waiting, subject: "Fabrik wartet") }
  let!(:start_wp) { create(:work_package, project: gen_child, author: admin, status: startfreigabe, subject: "Gen startet") }
  let!(:running_wp) { create(:work_package, project: flight, author: admin, status: in_arbeit, subject: "Flug laeuft") }

  def label(work_package, name)
    option = labels_field.custom_options.find_by!(value: name)
    CustomValue.create!(customized: work_package, custom_field: labels_field, value: option.id.to_s)
  end

  before do
    Rails.cache.clear
    ENV["FP_EXPORT_DIR"] = export_dir
    { ada => "ADA MAIN", flight => "ADA MAIN", factory => "ADA MAIN", gen => "NuovaGen", gen_child => "NuovaGen" }
      .each do |project, value|
        option = bereich_field.custom_options.find_by!(value:)
        CustomValue.create!(customized: project, custom_field: bereich_field, value: option.id.to_s)
      end
    label(waiting_wp, "P1")
    label(waiting_wp, "agent:autonom")
    label(start_wp, "<b>fett</b>")
    File.write(File.join(export_dir, "status.json"), JSON.generate(
      "gesamt" => "gelb", "heartbeat" => { "epoch" => Time.current.to_i },
      "pruefungen" => [{ "name" => "sync", "ampel" => "gelb" }, { "name" => "backup", "ampel" => "gruen" }]
    ))
    File.write(File.join(export_dir, "dispatch.json"), JSON.generate(
      "slots" => { "belegt" => 1, "maximum" => 4 }, "queue" => [],
      "letzte_starts" => [{ "op" => running_wp.id, "harness" => "claude", "modell" => "opus" }]
    ))
  end

  after do
    ENV.delete("FP_EXPORT_DIR")
    FileUtils.remove_entry(export_dir)
    Rails.cache.clear
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def widget(key)
    found = page.at_css("#fp-home .fp-home-main .fp-widgets > .fp-widget[data-fp-widget='#{key}']")
    expect(found).to be_present, "Widget #{key} fehlt"
    found
  end

  def items(key)
    widget(key).css("[data-fp-item]")
  end

  def item_data(node)
    {
      bereich: node["data-fp-area"],
      projects: JSON.parse(node["data-fp-projects"] || "[]"),
      statuses: JSON.parse(node["data-fp-statuses"] || "[]"),
      labels: JSON.parse(node["data-fp-labels"] || "[]")
    }
  end

  def option_values(select)
    select.css("option").map { |option| option["value"] }.reject(&:empty?)
  end

  describe "as admin" do
    current_user { admin }

    %w[/ /flightplan/dashboard].each do |path|
      it "puts the overview first, then attention, then the other widgets (#{path})" do
        get path
        expect(response).to have_http_status(:ok)
        keys = page.css("#fp-home .fp-home-main .fp-widgets > .fp-widget").map { |node| node["data-fp-widget"] }
        expect(keys).to eq(%w[overview attention running betrieb])
        expect(page.at_css("#content-body > #fp-home")).to be_present
      end
    end

    it "gives every widget a title, its own scroll area, a search field and an empty-result notice" do
      get "/"
      page.css(".fp-widgets > .fp-widget").each do |node|
        key = node["data-fp-widget"]
        title_id = node["aria-labelledby"]
        expect(node.at_css(".fp-widget-head h2##{title_id}")).to be_present, key
        body = node.at_css(".fp-widget-body[data-fp-widget-body]")
        expect(body).to be_present, key
        expect(body["tabindex"]).to eq("0")
        expect(node.at_css("[data-fp-widget-tools] input[type='search'][data-fp-filter='text']")).to be_present, key
        expect(body.at_css("[data-fp-widget-none][hidden]")).to be_present, key
        expect(node.at_css("[data-fp-widget-count]")).to be_present, key
      end
      expect(widget("attention").at_css(".fp-widget-head h2")["id"]).to eq("fp-dash-attention-title")
    end

    it "limits the height of every widget and scrolls inside, through the stylesheet" do
      get "/flightplan/assets/flightplan.css"
      css = response.body
      widget_rule = css[/\.fp-widget \{[^}]*\}/m]
      expect(widget_rule).to include("max-height:")
      expect(css[/\.fp-widget-body \{[^}]*\}/m]).to include("overflow: auto", "min-height: 0")
      expect(css[/\.fp-widgets \{[^}]*\}/m]).to include("display: grid", "auto-fill")
      expect(css).to match(/\.fp-widget--wide \{\s*grid-column: 1 \/ -1;/)
    end

    it "shows the Bereiche with their projects and subprojects in the overview" do
      get "/"
      ada_tile = widget("overview").at_css("[data-bereich-tile='ADA MAIN']")
      names = ada_tile.css("[data-fp-item]").map { |node| [node.at_css("a").text.strip, node["data-depth"]] }
      expect(names).to eq([["Widget Ada", "0"], ["Widget Flug", "1"], ["Widget Fabrik", "2"]])
      gen_tile = widget("overview").at_css("[data-bereich-tile='NuovaGen']")
      expect(gen_tile.css("[data-fp-item]").map { |node| node["data-depth"] }).to eq(%w[0 1])
      fabrik = ada_tile.css("[data-fp-item]").last
      expect(item_data(fabrik)).to eq(bereich: "ADA MAIN", projects: %w[widget-fabrik widget-flug widget-ada],
                                      statuses: ["Wartet auf Mensch"], labels: ["agent:autonom", "P1"])
    end

    it "offers project/Bereich, status and label filters in the overview" do
      get "/"
      tools = widget("overview").at_css("[data-fp-widget-tools]")
      scope = option_values(tools.at_css("select[data-fp-filter='scope']"))
      expect(scope).to include("bereich:ADA MAIN", "bereich:NuovaGen", "project:widget-ada", "project:widget-flug",
                               "project:widget-fabrik", "project:widget-gen-kind")
      expect(option_values(tools.at_css("select[data-fp-filter='status']")))
        .to include("Wartet auf Mensch", "Startfreigabe", "In Arbeit")
      expect(tools.css("[data-fp-filter='labels'] input[type='checkbox']").map { |box| box["value"] })
        .to contain_exactly("P1", "agent:autonom", "<b>fett</b>")
    end

    it "marks each attention row with Bereich, project path, status and labels and shows the labels" do
      get "/"
      row = widget("attention").at_css("tr[data-wp='#{waiting_wp.id}']")
      expect(row["data-fp-item"]).not_to be_nil
      expect(item_data(row)).to eq(bereich: "ADA MAIN", projects: %w[widget-fabrik widget-flug widget-ada],
                                   statuses: ["Wartet auf Mensch"], labels: ["P1", "agent:autonom"])
      expect(row.css(".fp-dash-label").map(&:text)).to eq(["P1", "agent:autonom"])
      gen_row = widget("attention").at_css("tr[data-wp='#{start_wp.id}']")
      expect(item_data(gen_row)[:labels]).to eq(["<b>fett</b>"])
      expect(response.body).not_to include("<b>fett</b>")
    end

    it "groups the attention rows so that the filter can hide empty Bereiche" do
      get "/"
      groups = widget("attention").css("[data-fp-group]")
      expect(groups.map { |group| group.at_css("[data-bereich-table]")["data-bereich-table"] }).to eq(["ADA MAIN", "NuovaGen"])
      expect(groups.first.at_css("[data-fp-group-count]").text.strip).to eq("1")
      tools = widget("attention").at_css("[data-fp-widget-tools]")
      expect(option_values(tools.at_css("select[data-fp-filter='status']"))).to eq(["Wartet auf Mensch", "Startfreigabe"])
      expect(option_values(tools.at_css("select[data-fp-filter='scope']"))).to include("bereich:ADA MAIN", "project:widget-gen")
    end

    it "keeps the label filter a plain multiple choice inside one group, ready for categories (OP#1670)" do
      get "/"
      labels = widget("attention").at_css("details[data-fp-filter='labels']")
      groups = labels.css("fieldset[data-fp-label-group]")
      expect(groups.size).to eq(1)
      expect(groups.first.at_css("legend")).to be_nil
      expect(Flightplan::WidgetFilters.label_groups(["b", "a", "b"]))
        .to eq([{ key: "alle", title: nil, names: %w[a b] }])
      expect(Flightplan::WidgetFilters.label_groups([])).to eq([])
    end

    it "lists running agents as filterable entries" do
      get "/"
      entry = items("running").first
      expect(entry.text).to include("Flug laeuft")
      expect(item_data(entry)).to include(bereich: "ADA MAIN", projects: %w[widget-flug widget-ada], statuses: ["In Arbeit"])
      expect(widget("running").at_css("article#fp-tile-agents[data-tile='agents']")).to be_present
    end

    it "lists health checks and versions with their lamp as status filter" do
      get "/"
      expect(widget("betrieb").at_css("article[data-tile='health']")).to be_present
      expect(widget("betrieb").at_css("article[data-tile='engine']")).to be_present
      checks = items("betrieb").map { |node| [node.text.squish, item_data(node)[:statuses]] }
      expect(checks).to include(["sync gelb", ["gelb"]], ["backup grün", ["grün"]])
      expect(option_values(widget("betrieb").at_css("select[data-fp-filter='status']"))).to eq(%w[grün gelb])
      expect(widget("betrieb").at_css("select[data-fp-filter='scope']")).to be_nil
    end

    it "keeps the Bereich chips on the home screen instead of leaving it" do
      get "/"
      chip = widget("attention").at_css("a.fp-chip[data-bereich='nuovagen']")
      expect(chip["href"]).to eq("/?bereich=nuovagen")
      get "/", params: { bereich: "nuovagen" }
      expect(widget("attention").text).to include("Gen startet")
      expect(widget("attention").text).not_to include("Fabrik wartet")
    end

    it "ships the widget filter script" do
      get "/flightplan/assets/flightplan.js"
      expect(response.body).to include("function fpWidgetFilters(", "[data-fp-widget]", "data-fp-filter", "fpLabelFilter")
    end
  end

  describe "as a user without admin rights" do
    let(:member) { create(:user, language: "de") }

    current_user { member }

    it "renders no widgets" do
      get "/"
      expect(response).to have_http_status(:ok)
      expect(page.at_css(".fp-widgets")).to be_nil
      expect(response.body).not_to include("data-fp-item")
    end
  end
end
