# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../../../spec_helper"
require "rack/test"

# OP#1842: Rückfrage mit Struktur (kind, recommended_option, reversible, consequence). Alle Felder optional und nullbar.
RSpec.describe "API v3 flightplan questions with structure", type: :request, content_type: :json do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  let(:permissions) { %i[view_work_packages add_work_package_comments edit_work_packages change_work_package_status] }
  let(:role) { create(:project_role, permissions:) }
  let(:project) { create(:project) }
  let(:agent) { create(:user, member_with_roles: { project => role }) }
  let(:work_package) { create(:work_package, project:, author: agent) }
  let(:dispatcher_role) { create(:project_role, permissions:) }
  let!(:waiting) { create(:status, name: "Wartet auf Mensch") }
  let!(:dispatcher) { create(:user, login: "dispatcher", member_with_roles: { project => dispatcher_role }) }
  let!(:transition) do
    create(:workflow, role: dispatcher_role, type: work_package.type, old_status: work_package.status, new_status: waiting)
  end

  before { login_as(agent) }

  def app
    Rails.application
  end

  def ask(extra = {})
    post "/api/v3/flightplan/questions", { work_package_id: work_package.id, question: "Variante?", options: %w[A B] }.merge(extra).to_json
  end

  it "stores and returns the structured fields, also in the lists" do
    ask(kind: "entscheidung", recommended_option: "B", reversible: false, consequence: "Danach neu bauen")

    expect(last_response.status).to eq(201), last_response.body
    body = JSON.parse(last_response.body)
    expect(body).to include("kind" => "entscheidung", "recommended_option" => "B", "reversible" => false,
                            "consequence" => "Danach neu bauen")

    get "/api/v3/flightplan/questions"
    listed = JSON.parse(last_response.body).fetch("questions").first
    expect(listed).to include("kind" => "entscheidung", "recommended_option" => "B", "reversible" => false)

    get "/api/v3/work_packages/#{work_package.id}/flightplan/questions"
    expect(JSON.parse(last_response.body).fetch("questions").first).to include("recommended_option" => "B")
  end

  it "accepts reversible as true and as the string false" do
    ask(reversible: true)
    expect(JSON.parse(last_response.body)["reversible"]).to be(true)

    ask(reversible: "false")
    expect(JSON.parse(last_response.body)["reversible"]).to be(false)
  end

  it "keeps the old form unchanged: all new fields are null" do
    ask

    expect(last_response.status).to eq(201), last_response.body
    body = JSON.parse(last_response.body)
    expect(body).to include("kind" => nil, "recommended_option" => nil, "reversible" => nil, "consequence" => nil)
    expect(body["options"]).to eq(%w[A B])
  end

  it "treats options and recommendation alike: both are trimmed" do
    post "/api/v3/flightplan/questions", { work_package_id: work_package.id, question: "Trim?", options: [" A ", "B"],
                                           recommended_option: " A " }.to_json

    expect(last_response.status).to eq(201), last_response.body
    expect(JSON.parse(last_response.body)).to include("options" => %w[A B], "recommended_option" => "A")
  end

  it "answers 422 when the recommendation is not among the options" do
    ask(recommended_option: "C")

    expect(last_response.status).to eq(422)
    expect(Flightplan::Question.count).to eq(0)
  end

  it "answers 422 for a recommendation without options" do
    post "/api/v3/flightplan/questions", { work_package_id: work_package.id, question: "Ohne?", recommended_option: "A" }.to_json

    expect(last_response.status).to eq(422)
  end

  it "answers 422 for an unknown kind" do
    ask(kind: "auto")

    expect(last_response.status).to eq(422)
    expect(Flightplan::Question.count).to eq(0)
  end

  it "answers 422 for a consequence over 500 characters and accepts exactly 500" do
    ask(consequence: "x" * 501)
    expect(last_response.status).to eq(422)

    ask(consequence: "x" * 500)
    expect(last_response.status).to eq(201), last_response.body
  end

  it "answers 422 for an unreadable reversible value" do
    ask(reversible: "vielleicht")

    expect(last_response.status).to eq(422)
  end
end
