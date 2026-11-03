# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../../../spec_helper"
require "rack/test"

RSpec.describe "API v3 flightplan questions", type: :request, content_type: :json do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  let(:permissions) { %i[view_work_packages add_work_package_comments edit_work_packages change_work_package_status] }
  let(:role) { create(:project_role, permissions:) }
  let(:dispatcher_role) { create(:project_role, permissions:) }
  let(:project) { create(:project) }
  let(:agent) { create(:user, member_with_roles: { project => role }) }
  let(:work_package) { create(:work_package, project:, author: agent) }
  let!(:waiting) { create(:status, name: "Wartet auf Mensch") }
  let!(:dispatcher) { create(:user, login: "dispatcher", member_with_roles: { project => dispatcher_role }) }
  let!(:transition) do
    create(:workflow, role: dispatcher_role, type: work_package.type, old_status: work_package.status, new_status: waiting)
  end

  before { login_as(agent) }

  def app
    Rails.application
  end

  it "creates a question, sets the waiting status, and refuses an agent answer" do
    post "/api/v3/flightplan/questions", {
      work_package_id: work_package.id,
      question: "Weiter?",
      options: ["ja"],
      context: "Spec"
    }.to_json

    expect(last_response.status).to eq(201), last_response.body
    body = JSON.parse(last_response.body)
    expect(body["author"]).to eq(agent.login)
    expect(body["status"]).to eq("open")
    expect(work_package.reload.status).to eq(waiting)

    post "/api/v3/flightplan/questions/#{body['id']}/answer", { option: "ja" }.to_json

    expect(last_response).to have_http_status(:forbidden)
    expect(Flightplan::Question.find(body["id"])).to be_open
  end

  it "answers a closed work package without restoring the status" do
    post "/api/v3/flightplan/questions", {
      work_package_id: work_package.id,
      question: "Trotzdem?",
      options: ["ja"]
    }.to_json
    expect(last_response.status).to eq(201), last_response.body
    question_id = JSON.parse(last_response.body).fetch("id")

    rejected = create(:status, name: "Abgelehnt", is_closed: true)
    create(:workflow, role: dispatcher_role, type: work_package.type, old_status: waiting, new_status: rejected)
    Flightplan::StatusChange.apply!(work_package.reload, rejected)
    expect(work_package.reload.status).to eq(rejected)

    login_as(create(:admin))
    post "/api/v3/flightplan/questions/#{question_id}/answer", { text: "erledigt" }.to_json

    expect(last_response.status).to eq(201), last_response.body
    body = JSON.parse(last_response.body)
    expect(body["status"]).to eq("answered")
    expect(body["answer"]).to eq("erledigt")
    expect(body["status_restored"]).to eq(false)
    expect(work_package.reload.status).to eq(rejected)
    expect(work_package.journals.order(:id).pluck(:notes).join).to include("Antwort: erledigt")
  end

  it "keeps the waiting status when the return transition is missing" do
    post "/api/v3/flightplan/questions", {
      work_package_id: work_package.id,
      question: "Zurück?"
    }.to_json
    expect(last_response.status).to eq(201), last_response.body
    question_id = JSON.parse(last_response.body).fetch("id")
    expect(work_package.reload.status).to eq(waiting)

    login_as(create(:admin))
    post "/api/v3/flightplan/questions/#{question_id}/answer", { text: "ja" }.to_json

    expect(last_response.status).to eq(201), last_response.body
    body = JSON.parse(last_response.body)
    expect(body["status_restored"]).to eq(false)
    expect(work_package.reload.status).to eq(waiting)
    expect(Flightplan::Question.find(question_id)).not_to be_open
  end

  it "does not remember a previous status when the package is already waiting" do
    Flightplan::StatusChange.apply!(work_package, waiting)
    expect(work_package.reload.status).to eq(waiting)

    post "/api/v3/flightplan/questions", {
      work_package_id: work_package.id,
      question: "Schon wartend?"
    }.to_json

    expect(last_response.status).to eq(201), last_response.body
    question_id = JSON.parse(last_response.body).fetch("id")
    expect(Flightplan::Question.find(question_id).previous_status_id).to be_nil
    expect(work_package.reload.status).to eq(waiting)

    login_as(create(:admin))
    post "/api/v3/flightplan/questions/#{question_id}/answer", { text: "bleibt" }.to_json

    expect(last_response.status).to eq(201), last_response.body
    expect(JSON.parse(last_response.body)["status_restored"]).to eq(false)
    expect(work_package.reload.status).to eq(waiting)
  end
end
