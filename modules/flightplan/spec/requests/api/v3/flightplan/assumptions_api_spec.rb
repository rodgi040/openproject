# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../../../spec_helper"
require "rack/test"

# OP#1839: Annahmen eines Agenten am Ticket (Vertrag Phase 2a, Abschnitt 1).
RSpec.describe "API v3 flightplan assumptions", type: :request, content_type: :json do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  let(:permissions) { %i[view_work_packages add_work_package_comments edit_work_packages] }
  let(:role) { create(:project_role, permissions:) }
  let(:human_role) { create(:project_role, name: "Mensch", permissions:) }
  let(:project) { create(:project) }
  let(:other_project) { create(:project) }
  let(:agent) { create(:user, login: "agent-annahme", member_with_roles: { project => role }) }
  let(:human) { create(:user, login: "mensch-annahme", member_with_roles: { project => human_role }) }
  let(:outsider) { create(:user, member_with_roles: { other_project => role }) }
  let(:work_package) { create(:work_package, project:, author: agent) }

  before { login_as(agent) }

  def app
    Rails.application
  end

  def assume(text = "Ich nehme Port 8094.", id: work_package.id)
    post "/api/v3/flightplan/assumptions", { work_package_id: id, text: }.to_json
  end

  it "creates an assumption, writes the comment and leaves the status alone" do
    status = work_package.status

    assume

    expect(last_response.status).to eq(201), last_response.body
    body = JSON.parse(last_response.body)
    expect(body).to include("work_package_id" => work_package.id, "text" => "Ich nehme Port 8094.", "status" => "open",
                            "author" => agent.login, "decided_by" => nil, "decided_at" => nil, "note" => nil)
    expect(body["id"]).to be_present
    expect(body["created_at"]).to be_present
    expect(work_package.reload.status).to eq(status)
    expect(work_package.journals.order(:id).pluck(:notes).compact).to include("Annahme: Ich nehme Port 8094.")
  end

  it "refuses a second open assumption on the same ticket with 422" do
    assume
    expect(last_response.status).to eq(201)

    assume("Zweite Annahme")

    expect(last_response.status).to eq(422)
    expect(last_response.body).to include("offene Annahme")
    expect(Flightplan::Assumption.where(work_package_id: work_package.id).count).to eq(1)
  end

  it "allows a new assumption after the first one was decided, and refuses empty or too long text" do
    assume
    Flightplan::Assumption.last.update!(status: "confirmed")
    assume("Neue Annahme")
    expect(last_response.status).to eq(201)

    other = create(:work_package, project:, author: agent)
    assume("", id: other.id)
    expect(last_response.status).to eq(422)
    assume("x" * 2001, id: other.id)
    expect(last_response.status).to eq(422)
  end

  it "does not let an agent decide (403) and keeps the assumption open" do
    assume
    id = JSON.parse(last_response.body).fetch("id")

    post "/api/v3/flightplan/assumptions/#{id}/decide", { decision: "confirmed" }.to_json

    expect(last_response).to have_http_status(:forbidden)
    expect(Flightplan::Assumption.find(id)).to be_open
  end

  it "lets the human role confirm, with a comment, and refuses to decide twice with 422" do
    assume
    id = JSON.parse(last_response.body).fetch("id")

    login_as(human)
    post "/api/v3/flightplan/assumptions/#{id}/decide", { decision: "confirmed" }.to_json

    expect(last_response.status).to eq(201), last_response.body
    body = JSON.parse(last_response.body)
    expect(body).to include("status" => "confirmed", "decided_by" => human.login)
    expect(body["decided_at"]).to be_present
    expect(work_package.journals.order(:id).pluck(:notes).compact).to include("Annahme bestätigt")

    post "/api/v3/flightplan/assumptions/#{id}/decide", { decision: "rejected", note: "doch nicht" }.to_json

    expect(last_response.status).to eq(422)
    expect(Flightplan::Assumption.find(id).status).to eq("confirmed")
  end

  it "rejects only with a note and writes it into the comment" do
    assume
    id = JSON.parse(last_response.body).fetch("id")
    login_as(create(:admin))

    post "/api/v3/flightplan/assumptions/#{id}/decide", { decision: "rejected" }.to_json
    expect(last_response.status).to eq(422)
    expect(Flightplan::Assumption.find(id)).to be_open

    post "/api/v3/flightplan/assumptions/#{id}/decide", { decision: "rejected", note: "Nimm 8095." }.to_json
    expect(last_response.status).to eq(201), last_response.body
    expect(JSON.parse(last_response.body)).to include("status" => "rejected", "note" => "Nimm 8095.")
    expect(work_package.journals.order(:id).pluck(:notes).compact).to include("Annahme verworfen: Nimm 8095.")
  end

  it "lists the assumptions of a ticket newest first, filtered by status, only for users who see the ticket" do
    assume("Erste")
    Flightplan::Assumption.last.update!(status: "rejected", note: "nein")
    assume("Zweite")

    get "/api/v3/work_packages/#{work_package.id}/flightplan/assumptions"
    expect(last_response.status).to eq(200), last_response.body
    expect(JSON.parse(last_response.body)["assumptions"].map { |item| item["text"] }).to eq(%w[Zweite Erste])

    get "/api/v3/work_packages/#{work_package.id}/flightplan/assumptions?status=open"
    expect(JSON.parse(last_response.body)["assumptions"].map { |item| item["text"] }).to eq(%w[Zweite])

    login_as(outsider)
    get "/api/v3/work_packages/#{work_package.id}/flightplan/assumptions"
    expect(last_response.status).to eq(404)
  end

  it "hides tickets the user cannot see when creating or deciding" do
    assume
    id = JSON.parse(last_response.body).fetch("id")

    login_as(outsider)
    assume("Heimlich")
    expect(last_response.status).to eq(404)
    post "/api/v3/flightplan/assumptions/#{id}/decide", { decision: "confirmed" }.to_json
    expect(last_response.status).to eq(404)
    expect(Flightplan::Assumption.find(id)).to be_open
  end
end
