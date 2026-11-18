# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

# OP#2841: Menüpunkt „Research“, Weiterleitung auf die gefilterte Arbeitspaketliste, Recherche nicht in Board und Dashboard.
RSpec.describe "Flightplan research", :skip_csrf, type: :rails_request do
  let(:role) { create(:project_role, permissions: %i[view_work_packages view_members]) }
  let(:recherche) { create(:type, name: "Recherche") }
  let(:aufgabe) { create(:type, name: "Aufgabe Research") }
  let(:project) { create(:project, name: "Research Fabrik", identifier: "research-fabrik", public: false, types: [recherche, aufgabe]) }
  let(:member) { create(:user, member_with_roles: { project => role }) }
  let!(:kurz) { create(:string_wp_custom_field, name: "Kurzantwort", projects: [project], types: [recherche]) }
  let!(:konfidenz) { create(:string_wp_custom_field, name: "Konfidenz", projects: [project], types: [recherche]) }

  def query_props_of(location)
    JSON.parse(Rack::Utils.parse_query(URI.parse(location).query).fetch("query_props"))
  end

  describe "menu" do
    current_user { member }

    it "shows the entry before Members when the type is active" do
      get "/projects/#{project.identifier}/work_packages"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/projects/research-fabrik/research")
      expect(response.body.index("/projects/research-fabrik/research")).to be < response.body.index("/projects/research-fabrik/members")
    end

    it "hides the entry when the project has no type Recherche" do
      other = create(:project, identifier: "ohne-recherche", public: false, types: [aufgabe])
      create(:member, project: other, principal: member, roles: [role])
      get "/projects/ohne-recherche/work_packages"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("/projects/ohne-recherche/research")
    end

    it "hides the entry when work package tracking is off" do
      project.enabled_module_names -= ["work_package_tracking"]
      expect(Flightplan::Research.visible_in?(project.reload)).to be(false)
    end
  end

  describe "show" do
    current_user { member }

    it "redirects to the work package list with type, all statuses, subprojects, columns and sort" do
      get "/projects/#{project.identifier}/research"
      expect(response).to have_http_status(:found)
      expect(response.location).to include("/projects/research-fabrik/work_packages?query_props=")
      props = query_props_of(response.location)
      expect(props["f"]).to eq([
        { "n" => "type", "o" => "=", "v" => [recherche.id.to_s] },
        { "n" => "status", "o" => "*" },
        { "n" => "subprojectId", "o" => "*" }
      ])
      expect(props["c"]).to eq(["id", "subject", "project", "customField#{kurz.id}", "customField#{konfidenz.id}", "updatedAt"])
      expect(props["t"]).to eq("updated_at:desc")
    end

    it "omits a column whose field does not exist" do
      konfidenz.destroy
      get "/projects/#{project.identifier}/research"
      expect(query_props_of(response.location)["c"]).to eq(["id", "subject", "project", "customField#{kurz.id}", "updatedAt"])
    end

    it "redirects to the plain list with a notice when the type is not active in the project" do
      ProjectType.where(project_id: project.id, type_id: recherche.id).delete_all
      get "/projects/#{project.identifier}/research"
      expect(response).to redirect_to("/projects/research-fabrik/work_packages")
      expect(flash[:notice]).to eq(I18n.t("flightplan.research.missing_type"))
    end

    it "answers 403 without the permission" do
      outsider_role = create(:project_role, permissions: [])
      user = create(:user, member_with_roles: { project => outsider_role })
      login_as user
      get "/projects/#{project.identifier}/research"
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "board and dashboard" do
    let(:admin) { create(:admin) }
    let!(:neu) { Status.find_by(name: "Neu") || create(:status, name: "Neu") }
    let!(:regular) { create(:work_package, project:, author: member, type: aufgabe, status: neu, subject: "Normales Paket") }
    let!(:research) { create(:work_package, project:, author: member, type: recherche, status: neu, subject: "Recherche Paket") }

    it "leaves research packages out of the board" do
      login_as member
      get "/"
      expect(response.body).to include("Normales Paket")
      expect(response.body).not_to include("Recherche Paket")
    end

    it "leaves research packages out of the dashboard counts" do
      expect(Flightplan::Dashboard.check_report(user: admin)[:statuses]["Neu"]).to eq(1)
    end

    it "keeps every package when the type does not exist" do
      research.update_columns(type_id: aufgabe.id)
      recherche.destroy
      expect(Flightplan::Research.excluding(WorkPackage.where(project_id: project.id)).count).to eq(2)
    end
  end
end
