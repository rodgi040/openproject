# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

RSpec.describe "Flightplan board", :skip_csrf, type: :rails_request do
  def ensure_status(name, closed: false)
    status = Status.find_by(name:) || create(:status, name:, is_closed: closed)
    status.update!(is_closed: closed) if status.is_closed? != closed
    status
  end

  def column_html(key)
    response.body[/data-column="#{key}" data-count="\d+" data-status="[^"]*">.*?<\/section>/m]
  end

  def column_count(key)
    response.body[/data-column="#{key}" data-count="(\d+)"/, 1].to_i
  end

  describe "index" do
    let(:role) { create(:project_role, permissions: %i[view_work_packages]) }
    let(:default_type) { create(:type, name: "Aufgabe Board") }
    let(:dach) { create(:type, name: "Dach") }
    let(:project) { create(:project, name: "Board Factory", public: false, types: [default_type, dach]) }
    let(:other) { create(:project, name: "Board Ada", public: false) }
    let(:hidden) { create(:project, name: "Board Secret", public: false) }
    let(:member) { create(:user, member_with_roles: { project => role, other => role }) }
    let(:agent) { create(:user, member_with_roles: { project => role }) }
    let!(:coding) { create(:group, lastname: "Agenten Coding", members: [agent]) }
    let!(:neu) { ensure_status("Neu") }
    let!(:geplant) { ensure_status("Geplant") }
    let!(:startfreigabe) { ensure_status("Startfreigabe") }
    let!(:in_arbeit) { ensure_status("In Arbeit") }
    let!(:waiting) { ensure_status("Wartet auf Mensch") }
    let!(:review) { ensure_status("Review") }
    let!(:fertig) { ensure_status("Fertig", closed: true) }
    let!(:abgelehnt) { ensure_status("Abgelehnt", closed: true) }
    let!(:labels) do
      create(:multi_list_wp_custom_field, name: "Labels", possible_values: %w[bug enhancement], projects: [project, other])
    end
    let!(:pause_field) { create(:text_wp_custom_field, name: "Pausenstand", projects: [project]) }
    let!(:path_field) do
      create(:list_wp_custom_field, name: "Ausführungsweg", possible_values: %w[engine claude], projects: [project])
    end

    let!(:visible_new) { create(:work_package, project:, author: member, status: neu, subject: "Sichtbar Neu") }
    let!(:bug_wp) { create(:work_package, project:, author: member, status: neu, subject: "Bugpaket") }
    let!(:dach_wp) { create(:work_package, project:, author: member, type: dach, status: neu, subject: "Dachpaket") }
    let!(:child_wp) { create(:work_package, project:, author: member, status: neu, subject: "Kindpaket") }
    let!(:for_human) { create(:work_package, project:, author: member, status: geplant, subject: "Geplant Mensch") }
    let!(:for_agent) do
      create(:work_package, project:, author: member, status: geplant, assigned_to: agent, subject: "Geplant Agent")
    end
    let!(:ready) { create(:work_package, project:, author: member, status: startfreigabe, subject: "Bereit") }
    let!(:question_wp) { create(:work_package, project:, author: member, status: waiting, subject: "Wartet Paket") }
    let!(:progress) { create(:work_package, project:, author: member, status: in_arbeit, subject: "Laeuft") }
    let!(:review_wp) { create(:work_package, project:, author: member, status: review, subject: "Pruefen") }
    let!(:fresh_done) { create(:work_package, project:, author: member, status: fertig, subject: "Frisch fertig") }
    let!(:old_done) { create(:work_package, project:, author: member, status: fertig, subject: "Alt fertig") }
    let!(:rejected) { create(:work_package, project:, author: member, status: abgelehnt, subject: "Abgelehnt Paket") }
    let!(:other_wp) { create(:work_package, project: other, author: member, status: neu, subject: "Anderes Neu") }
    let!(:secret_wp) { create(:work_package, project: hidden, author: member, status: neu, subject: "Geheim Neu") }
    let!(:factory_question) do
      Flightplan::Question.create!(work_package: question_wp, author: agent, question: "Frage auf Factory", status: "open")
    end
    let!(:ada_question) do
      Flightplan::Question.create!(work_package: other_wp, author: agent, question: "Frage auf Ada", status: "open")
    end

    current_user { member }

    before do
      child_wp.update_columns(parent_id: dach_wp.id)
      bug_option = labels.custom_options.find_by!(value: "bug")
      CustomValue.create!(customized: bug_wp, custom_field: labels, value: bug_option.id.to_s)
      CustomValue.create!(customized: visible_new, custom_field: pause_field, value: "steht")
      engine = path_field.custom_options.find_by!(value: "engine")
      CustomValue.create!(customized: visible_new, custom_field: path_field, value: engine.id.to_s)
      Journal.where(journable_id: old_done.id, journable_type: "WorkPackage")
        .update_all(created_at: 40.days.ago, updated_at: 40.days.ago)
      old_done.update_columns(updated_at: 40.days.ago, created_at: 40.days.ago)
    end

    it "counts visible packages into the status columns" do
      get "/flightplan/assets/flightplan.js"
      expect(response).to have_http_status(:ok), response.body
      expect(response.body).to include("fp:card-selected")
      expect(response.body).to include('postMessage(message, origin)')
      expect(response.body).to include('event.origin !== origin')
      expect(response.body).not_to include("postMessage(message, '*'")
      expect(response.body).not_to include('postMessage(message, "*"')

      get "/flightplan/board"

      expect(response).to have_http_status(:ok), response.body
      expect(response.body).not_to include('id="fp-chat-panel"')
      expect(response.body).not_to include("data-fp-chat-frame")
      expect(response.body).not_to include("http://localhost:8092")
      directory = response.body[/id="fp-agent-directory">(.*?)<\/script>/m, 1]
      expect(directory).not_to include("&quot;")
      expect { JSON.parse(directory) }.not_to raise_error
      expect(column_count("triage")).to eq(5)
      expect(column_count("question")).to eq(1)
      expect(column_count("for_you")).to eq(1)
      expect(column_count("agent_ready")).to eq(2)
      expect(column_count("in_progress")).to eq(1)
      expect(column_count("review")).to eq(1)
      expect(column_count("done")).to eq(1)
      expect(response.body).not_to include('data-column="rejected"')

      expect(column_html("triage")).to include("Sichtbar Neu", "Bugpaket", "Dachpaket", "Kindpaket", "Anderes Neu")
      expect(column_html("for_you")).to include("Geplant Mensch")
      expect(column_html("agent_ready")).to include("Geplant Agent", "Bereit")
      expect(column_html("question")).to include("Wartet Paket", "#q-#{factory_question.id}")
      expect(column_html("done")).to include("Frisch fertig")
      expect(column_html("done")).not_to include("Alt fertig")
      expect(response.body).not_to include("Geheim Neu", "Abgelehnt Paket", "Alt fertig")
      expect(column_html("triage")).to include(I18n.t("flightplan.board.pause"), "engine", 'data-children="1"')
      expect(response.body).to include("d73a4a")
      expect(response.body).to include(
        project_wiki_path(project, project.wiki&.start_page.presence || "wiki"),
        project_wiki_path(other, other.wiki&.start_page.presence || "wiki")
      )
      expect(response.body).not_to include("/projects/#{hidden.identifier}/wiki")

      open_in_project = WorkPackage.visible(member).joins(:status).where(statuses: { is_closed: false }, project_id: project.id).count
      expect(response.body).to match(/data-project="#{project.identifier}"[^>]*data-open="#{open_in_project}"/)
      expect(response.body).not_to include(%(data-project="#{hidden.identifier}"))
    end

    it "filters labels and projects and keeps the inbox on the same projects" do
      get "/flightplan/board?labels=bug&projects=#{project.identifier},#{other.identifier}"

      expect(column_count("triage")).to eq(1)
      expect(response.body).to include("Bugpaket")
      expect(response.body).not_to include("Sichtbar Neu", "Anderes Neu")

      get "/flightplan/board?projects=#{project.identifier}"
      expect(response.body).to include("Sichtbar Neu")
      expect(response.body).not_to include("Anderes Neu")

      get "/flightplan/board?q=%23#{visible_new.id}"
      expect(response.body).to include("Sichtbar Neu")
      expect(response.body).not_to include("Bugpaket", "Anderes Neu")

      get "/flightplan/board?agents=coding"
      expect(response.body).to include("Geplant Agent")
      expect(response.body).not_to include("Geplant Mensch", "Sichtbar Neu")

      get "/flightplan/board?done=all&rejected=1"
      expect(response.body).to include("Alt fertig", "Abgelehnt Paket")

      get "/flightplan/questions?projects=#{project.identifier}"
      expect(response.body).to include("Frage auf Factory")
      expect(response.body).not_to include("Frage auf Ada")
    end

    it "caps a column limit at 500" do
      get "/flightplan/board", params: { limits: { triage: 900 } }

      expect(response.body).to include('name="limits[triage]"')
      expect(response.body).to include('value="500"')
      expect(response.body).not_to include('value="900"')
    end

    it "leaves the chat origin in CSP and does not render the board panel" do
      login_as create(:admin)
      get "/flightplan/board"

      expect(response).to have_http_status(:ok), response.body
      expect(response.body).not_to include('id="fp-chat-panel"')
      expect(response.body).not_to include("data-fp-chat-frame")
      header = response.headers["Content-Security-Policy"].to_s
      expect(header).to include("frame-src")
      expect(header).to include("child-src")
      expect(header).to include("http://localhost:8092")
    end

    it "filters packages by the top-level project" do
      roof = create(:project, name: "Dach Filter", public: false, workspace_type: "portfolio")
      inside = create(:project, name: "Dach Kind", parent: roof, public: false)
      outside = create(:project, name: "Neben Filter", public: false)
      role_filter = create(:project_role, permissions: %i[view_work_packages])
      viewer = create(:user, member_with_roles: { roof => role_filter, inside => role_filter, outside => role_filter })
      create(:work_package, project: inside, author: viewer, status: neu, subject: "Im Dach")
      create(:work_package, project: outside, author: viewer, status: neu, subject: "Ausserhalb Dach")
      login_as viewer

      get "/flightplan/board", params: { bereich: roof.identifier }

      expect(response).to have_http_status(:ok), response.body
      expect(response.body).to include("data-bereich=\"#{roof.identifier}\"")
      expect(response.body).to include("data-project=\"#{inside.identifier}\"")
      expect(response.body).not_to include("data-project=\"#{outside.identifier}\"")
      expect(response.body).to include("Im Dach")
      expect(response.body).not_to include("Ausserhalb Dach")
    end

    it "redirects the menu target" do
      get "/flightplan"

      expect(response).to redirect_to("/flightplan/board")
    end
  end

  describe "move" do
    let(:project) { create(:project, public: false) }
    let(:role) do
      create(:project_role, permissions: %i[view_work_packages edit_work_packages change_work_package_status])
    end
    let(:human) { create(:user, member_with_roles: { project => role }) }
    let(:agent_role) do
      create(:project_role, permissions: %i[view_work_packages edit_work_packages change_work_package_status])
    end
    let(:agent) { create(:user, member_with_roles: { project => agent_role }) }
    let(:admin) { create(:admin) }
    let!(:neu) { ensure_status("Neu") }
    let!(:geplant) { ensure_status("Geplant") }
    let!(:startfreigabe) { ensure_status("Startfreigabe") }
    let!(:wp) { create(:work_package, project:, author: human, status: neu, subject: "Zieh mich") }
    let(:hidden_project) { create(:project, public: false) }
    let!(:hidden_wp) { create(:work_package, project: hidden_project, author: human, status: neu, subject: "Versteckt") }

    before do
      [neu, geplant, startfreigabe].permutation(2).each do |from, to|
        create(:workflow, type: wp.type, role:, old_status: from, new_status: to)
      end
      create(:workflow, type: wp.type, role: agent_role, old_status: neu, new_status: geplant)
    end

    it "moves Neu to Geplant for an admin and rejects a stale lock" do
      login_as admin
      post "/flightplan/board/move", params: { id: wp.id, column: "for_you", lock_version: wp.lock_version }

      expect(response).to have_http_status(:ok), response.body
      expect(wp.reload.status).to eq(geplant)

      post "/flightplan/board/move", params: { id: wp.id, column: "triage", lock_version: wp.lock_version + 5 }

      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(response.body).to match(/updated|meantime|geändert|conflict|Konflikt/i)
      expect(wp.reload.status).to eq(geplant)
    end

    it "rejects Startfreigabe for an agent" do
      login_as agent
      post "/flightplan/board/move", params: { id: wp.id, column: "agent_ready", lock_version: wp.lock_version }

      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(JSON.parse(response.body)["error"]).to match(/transition|Übergang|invalid|ungültig/i)
      expect(wp.reload.status).to eq(neu)
    end

    it "rejects a missing lock version" do
      login_as admin
      post "/flightplan/board/move", params: { id: wp.id, column: "for_you", lock_version: nil }

      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(JSON.parse(response.body)["error"]).to eq("lockVersion fehlt")
      expect(wp.reload.status).to eq(neu)
    end

    it "does not move a package the user cannot see" do
      login_as human
      post "/flightplan/board/move", params: { id: hidden_wp.id, column: "for_you", lock_version: hidden_wp.lock_version }

      expect(response).to have_http_status(:not_found)
      expect(hidden_wp.reload.status).to eq(neu)
    end
  end
end
