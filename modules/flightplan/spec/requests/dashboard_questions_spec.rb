# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"
require "tmpdir"

# OP#1673: Die Seite „Rückfragen“ (/flightplan/questions, auch je Projekt) geht im ADA-Dashboard auf. Das Widget
# „Rückfragen“ steht direkt unter „Aufmerksamkeit“ und zeigt die offenen Rückfragen aller sichtbaren Projekte mit Projekt,
# Ticket, Frage, Agent und Alter; beantwortet wird direkt im Widget über die bisherige Antwort-Route. Die alte Seite leitet
# auf die Startseite um, die Menüeinträge entfallen.
RSpec.describe "Flightplan questions widget", :skip_csrf, type: :rails_request do
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
  let!(:ada) { create(:project, name: "Frage Ada", identifier: "ada-main", public: false) }
  let!(:factory) { create(:project, name: "Frage Fabrik", identifier: "frage-fabrik", parent: ada, public: false) }
  let!(:gen) { create(:project, name: "Frage Gen", identifier: "nuovagen", public: false) }
  let(:admin) { create(:admin, language: "de") }
  let!(:neu) { ensure_status("Neu") }
  let!(:waiting) { ensure_status("Wartet auf Mensch") }
  let!(:startfreigabe) { ensure_status("Startfreigabe") }
  let!(:in_arbeit) { ensure_status("In Arbeit") }
  let!(:labels_field) do
    create(:multi_list_wp_custom_field, name: "Labels", possible_values: %w[P1 agent:autonom], projects: [ada, factory, gen])
  end
  let(:agent) { create(:user, firstname: "Coda", lastname: "Agentin", login: "coda") }
  let!(:coding) { create(:group, lastname: "Agenten Coding", members: [agent]) }

  let!(:factory_wp) { create(:work_package, project: factory, author: admin, status: waiting, subject: "Fabrik fragt") }
  let!(:gen_wp) { create(:work_package, project: gen, author: admin, status: waiting, subject: "Gen fragt") }
  let!(:factory_question) do
    Flightplan::Question.create!(work_package: factory_wp, author: agent, question: "Welcher Port <b>soll</b> es sein?",
                                 context: "Port 8092 ist belegt.", options: %w[8093 8094], status: "open",
                                 previous_status: neu, created_at: 3.hours.ago)
  end
  let!(:gen_question) do
    Flightplan::Question.create!(work_package: gen_wp, author: agent, question: "Darf ich mergen?", status: "open",
                                 created_at: 2.days.ago)
  end
  let!(:answered) do
    Flightplan::Question.create!(work_package: gen_wp, author: agent, question: "Schon erledigt?", status: "answered",
                                 answer: "ja", answered_by: admin, answered_at: 1.hour.ago)
  end

  before do
    Rails.cache.clear
    ENV["FP_EXPORT_DIR"] = export_dir
    { ada => "ADA MAIN", factory => "ADA MAIN", gen => "NuovaGen" }.each do |project, value|
      option = bereich_field.custom_options.find_by!(value:)
      CustomValue.create!(customized: project, custom_field: bereich_field, value: option.id.to_s)
    end
    option = labels_field.custom_options.find_by!(value: "P1")
    CustomValue.create!(customized: factory_wp, custom_field: labels_field, value: option.id.to_s)
  end

  after do
    ENV.delete("FP_EXPORT_DIR")
    FileUtils.remove_entry(export_dir)
    Rails.cache.clear
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def questions_widget
    found = page.at_css("#fp-home .fp-home-main .fp-widgets > .fp-widget[data-fp-widget='questions']")
    expect(found).to be_present, "Widget questions fehlt"
    found
  end

  def item(question)
    node = questions_widget.at_css("[data-fp-item][data-fp-question='#{question.id}']")
    expect(node).to be_present, "Rückfrage #{question.id} fehlt"
    node
  end

  describe "as admin" do
    current_user { admin }

    %w[/ /flightplan/dashboard].each do |path|
      it "puts the questions widget directly after attention, full width (#{path})" do
        get path
        expect(response).to have_http_status(:ok)
        keys = page.css("#fp-home .fp-home-main .fp-widgets > .fp-widget").map { |node| node["data-fp-widget"] }
        expect(keys).to eq(%w[overview attention questions board running betrieb])
        expect(questions_widget["class"]).to include("fp-widget--wide")
        expect(questions_widget.at_css(".fp-widget-head h2").text).to eq("Rückfragen")
        expect(questions_widget.at_css("[data-fp-widget-count]").text.strip).to eq("2")
      end
    end

    it "lists the open questions of all projects with project, ticket link, question, agent and age" do
      get "/"
      texts = questions_widget.css("[data-fp-item]").map { |node| node.at_css(".fp-q-text").text.strip }
      expect(texts).to eq(["Welcher Port <b>soll</b> es sein?", "Darf ich mergen?"])
      expect(questions_widget.text).not_to include("Schon erledigt?")
      node = item(factory_question)
      expect(node["id"]).to eq("q-#{factory_question.id}")
      expect(node.at_css(".fp-q-project").text).to eq("Frage Fabrik")
      link = node.at_css("a.fp-q-id")
      expect(link.text).to eq("##{factory_wp.id}")
      expect(link["href"]).to eq("/flightplan/work_packages/#{factory_wp.id}")
      expect(node.at_css("a.fp-q-subject").text).to eq("Fabrik fragt")
      expect(node.at_css(".fp-q-context").text).to eq("Port 8092 ist belegt.")
      expect(node.at_css(".fp-q-agent").text).to include("Coda Agentin", "Agent · Coding")
      expect(node.at_css("time.fp-q-age").text).to eq("3 Std.")
      expect(item(gen_question).at_css("time.fp-q-age").text).to eq("2 T")
      expect(response.body).not_to include("<b>soll</b>")
    end

    it "groups the questions by Bereich and marks them for search and filter" do
      get "/"
      groups = questions_widget.css("[data-fp-group]")
      expect(groups.map { |group| group["data-questions-group"] }).to eq(["ADA MAIN", "NuovaGen"])
      node = item(factory_question)
      expect(node["data-fp-area"]).to eq("ADA MAIN")
      expect(JSON.parse(node["data-fp-projects"])).to eq(%w[frage-fabrik ada-main])
      expect(JSON.parse(node["data-fp-statuses"])).to eq(["Wartet auf Mensch"])
      expect(JSON.parse(node["data-fp-labels"])).to eq(["P1"])
      tools = questions_widget.at_css("[data-fp-widget-tools]")
      expect(tools.at_css("input[type='search'][data-fp-filter='text']")).to be_present
      scope = tools.css("select[data-fp-filter='scope'] option").map { |option| option["value"] }
      expect(scope).to include("bereich:ADA MAIN", "bereich:NuovaGen", "project:frage-fabrik", "project:nuovagen")
      expect(tools.css("select[data-fp-filter='status'] option").map { |option| option["value"] }.compact_blank)
        .to eq(["Wartet auf Mensch"])
      expect(tools.css("[data-fp-filter='labels'] input[type='checkbox']").map { |box| box["value"] }).to eq(["P1"])
    end

    it "offers the answer directly in the widget, through the existing answer route" do
      get "/"
      form = item(factory_question).at_css("form[data-fp-question-form]")
      expect(form["action"]).to eq("/flightplan/questions/#{factory_question.id}/answer")
      expect(form["method"]).to eq("post")
      expect(form.css("button[name='option']").map { |button| button["value"] }).to eq(%w[8093 8094])
      expect(form.at_css("textarea[name='text']")).to be_present
      expect(form.at_css("input[name='return_to']")["value"]).to eq("home")
      free = item(gen_question).at_css("form[data-fp-question-form]")
      expect(free.css("button[name='option']")).to be_empty
      expect(free.at_css("button[type='submit']")).to be_present

      get "/flightplan/dashboard"
      expect(item(factory_question).at_css("input[name='return_to']")["value"]).to eq("dashboard")
    end

    it "answers from the widget and returns to the home screen, at the next open question" do
      post "/flightplan/questions/#{factory_question.id}/answer",
           params: { option: "8093", text: "nimm 8093", return_to: "home" }
      expect(response).to redirect_to("/#q-#{gen_question.id}")
      expect(flash[:notice]).to eq("Beantwortet.")
      factory_question.reload
      expect(factory_question).not_to be_open
      expect(factory_question.chosen_option).to eq("8093")
      expect(factory_question.answer).to eq("nimm 8093")
      expect(factory_wp.journals.last.notes).to include("Option: 8093", "Antwort: nimm 8093")

      get "/"
      expect(questions_widget.at_css("[data-fp-question='#{factory_question.id}']")).to be_nil
      expect(questions_widget.at_css("[data-fp-widget-count]").text.strip).to eq("1")
    end

    it "returns to the dashboard page and to the widget once no question is left" do
      post "/flightplan/questions/#{gen_question.id}/answer", params: { text: "ja", return_to: "dashboard" }
      expect(response).to redirect_to("/flightplan/dashboard#q-#{factory_question.id}")
      post "/flightplan/questions/#{factory_question.id}/answer", params: { option: "8094", return_to: "dashboard" }
      expect(response).to redirect_to("/flightplan/dashboard#fp-widget-questions")
    end

    it "keeps an error visible on the home screen and leaves the question open" do
      post "/flightplan/questions/#{factory_question.id}/answer", params: { option: "9999", return_to: "home" }
      expect(response).to redirect_to("/#q-#{factory_question.id}")
      expect(flash[:alert]).to eq("Option unbekannt")
      expect(factory_question.reload).to be_open
    end

    it "redirects the old page to the widget on the home screen" do
      get "/flightplan/questions"
      expect(response).to redirect_to("/?rueckfragen=alle")
      get "/projects/frage-fabrik/flightplan/questions"
      expect(response).to redirect_to("/?rueckfragen=project%3Afrage-fabrik")
      get "/flightplan/questions", params: { project: "nuovagen" }
      expect(response).to redirect_to("/?rueckfragen=project%3Anuovagen")
      get "/flightplan/questions", params: { projects: "nuovagen" }
      expect(response).to redirect_to("/?rueckfragen=project%3Anuovagen")
    end

    it "keeps the JSON list of the old page" do
      get "/flightplan/questions", headers: { "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body)["items"].map { |entry| entry["id"] }
      expect(ids).to eq([gen_question.id, factory_question.id])
    end

    it "preselects the project or Bereich of the redirect in the widget filter" do
      get "/", params: { rueckfragen: "project:frage-fabrik" }
      selected = questions_widget.at_css("select[data-fp-filter='scope'] option[selected]")
      expect(selected["value"]).to eq("project:frage-fabrik")
      get "/", params: { rueckfragen: "bereich:NuovaGen" }
      expect(questions_widget.at_css("select[data-fp-filter='scope'] option[selected]")["value"]).to eq("bereich:NuovaGen")
      get "/", params: { rueckfragen: "alle" }
      expect(questions_widget.at_css("select[data-fp-filter='scope'] option[selected]")).to be_nil
    end

    it "links the question count of a Bereich tile to the widget" do
      get "/"
      link = page.at_css("[data-bereich-tile='NuovaGen'] [data-stat='questions'] a")
      expect(link.text).to eq("1")
      expect(link["href"]).to eq("/?rueckfragen=bereich%3ANuovaGen")
    end

    it "drops the menu entries of the old page" do
      get "/"
      expect(response).to have_http_status(:ok)
      expect(page.css("a[href$='/flightplan/questions']")).to be_empty
      get "/projects/frage-fabrik/work_packages"
      expect(page.css("a[href*='flightplan/questions']")).to be_empty
      expect(Redmine::MenuManager.items(:global_menu).map(&:name)).not_to include(:flightplan_questions)
      expect(Redmine::MenuManager.items(:project_menu).map(&:name)).not_to include(:flightplan_questions)
    end

    it "points notification and board links at the widget instead of the old page" do
      links = Flightplan::Menu.open_question_links(admin)
      expect(links).to include({ work_package_id: factory_wp.id, href: "/#q-#{factory_question.id}" })
    end

    it "sends the open questions to the chat column as fp:questions" do
      get "/"
      node = page.at_css("#fp-home-chat script[type='application/json'][data-fp-chat-questions]")
      expect(node).to be_present
      items = JSON.parse(node.text)
      expect(items.map { |entry| entry["id"] }).to eq([gen_question.id, factory_question.id])
      expect(items.last).to include("question" => "Welcher Port <b>soll</b> es sein?", "options" => %w[8093 8094],
                                    "work_package_id" => factory_wp.id, "project" => "frage-fabrik")
      get "/flightplan/assets/flightplan.js"
      expect(response.body).to include("[data-fp-chat-questions]", "data-fp-question-form", "fp:questions-changed")
    end
  end

  describe "as a user without admin rights" do
    let(:viewer_role) { create(:project_role, permissions: %i[view_work_packages add_work_package_comments]) }
    let(:mensch_role) { create(:project_role, name: "Mensch", permissions: %i[view_work_packages add_work_package_comments]) }
    let(:member) { create(:user, language: "de", member_with_roles: { factory => viewer_role }) }
    let(:human) { create(:user, language: "de", member_with_roles: { factory => mensch_role }) }

    describe "who only views" do
      current_user { member }

      it "shows only the questions widget, with the questions of visible projects" do
        get "/"
        expect(response).to have_http_status(:ok)
        expect(page.at_css("#fp-dashboard")).to be_nil
        keys = page.css("#fp-home .fp-home-main .fp-widgets > .fp-widget").map { |node| node["data-fp-widget"] }
        expect(keys).to eq(%w[questions board])
        expect(questions_widget.css("[data-fp-item]").map { |node| node["data-fp-question"] })
          .to eq([factory_question.id.to_s])
        expect(page.at_css("#fp-home-chat [data-fp-chat-questions]")).to be_nil
      end

      it "keeps the answer rights: viewing alone does not allow an answer" do
        post "/flightplan/questions/#{factory_question.id}/answer", params: { option: "8093", return_to: "home" }
        expect(response).to redirect_to("/#q-#{factory_question.id}")
        expect(flash[:alert]).to eq("Antworten ist der Rolle Mensch oder einem Admin vorbehalten")
        expect(factory_question.reload).to be_open
      end

      it "does not reveal a question of an invisible project" do
        post "/flightplan/questions/#{gen_question.id}/answer", params: { text: "x", return_to: "home" }
        expect(response).to have_http_status(:not_found)
        expect(gen_question.reload).to be_open
      end

      it "redirects the old page to the home screen as well" do
        get "/flightplan/questions"
        expect(response).to redirect_to("/?rueckfragen=alle")
      end
    end

    describe "with the role Mensch" do
      current_user { human }

      it "answers from the widget" do
        post "/flightplan/questions/#{factory_question.id}/answer", params: { option: "8094", return_to: "home" }
        expect(response).to redirect_to("/#fp-widget-questions")
        expect(factory_question.reload.chosen_option).to eq("8094")
      end

      it "is never sent to the admin-only dashboard page" do
        post "/flightplan/questions/#{factory_question.id}/answer", params: { option: "8094", return_to: "dashboard" }
        expect(response).to redirect_to("/#fp-widget-questions")
      end
    end
  end
end

RSpec.describe "Flightplan questions widget with CSRF protection", type: :rails_request do
  let(:admin) { create(:admin, language: "de") }
  let(:project) { create(:project, public: false) }
  let(:work_package) { create(:work_package, project:, author: admin) }
  let!(:question) do
    Flightplan::Question.create!(work_package:, author: admin, question: "Mit Token?", status: "open")
  end

  current_user { admin }

  around do |example|
    state = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = state
  end

  it "puts the CSRF token into the widget form and rejects an answer without it" do
    get "/"
    form = Nokogiri::HTML(response.body).at_css("form[data-fp-question-form]")
    expect(form.at_css("input[name='authenticity_token']")["value"]).to be_present

    post "/flightplan/questions/#{question.id}/answer", params: { text: "ohne Token" }
    expect(question.reload).to be_open
  end
end
