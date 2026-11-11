# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../../../spec_helper"
require "rack/test"

# OP#1843: GET /api/v3/flightplan/shadow/summary, nur Admin.
RSpec.describe "API v3 flightplan shadow summary", type: :request, content_type: :json do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  let(:project) { create(:project) }
  let(:work_package) { create(:work_package, project:) }

  def app
    Rails.application
  end

  def row(matched:, would_auto:)
    Flightplan::ShadowDecision.create!(source: "ask", work_package:, chosen: "A", matched:, would_auto:, rule: "x")
  end

  it "gives an admin the counts, with wrong = would_auto and not matched" do
    row(matched: true, would_auto: true)
    row(matched: false, would_auto: true)
    row(matched: false, would_auto: false)
    login_as(create(:admin))

    get "/api/v3/flightplan/shadow/summary"

    expect(last_response.status).to eq(200), last_response.body
    expect(JSON.parse(last_response.body)).to include("total" => 3, "matched" => 1, "would_auto" => 2, "wrong" => 1,
                                                      "rule" => "SHADOW_RULE_V1")
  end

  it "refuses a non-admin" do
    login_as(create(:user, member_with_roles: { project => create(:project_role, permissions: %i[view_work_packages]) }))

    get "/api/v3/flightplan/shadow/summary"

    expect(last_response).to have_http_status(:forbidden)
  end
end
