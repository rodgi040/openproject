# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

# OP#1706: Die globale Suche springt bei `#<id>` direkt auf das sichtbare Arbeitspaket.
RSpec.describe "Flightplan Suche nach #<id>", :skip_csrf, type: :rails_request do
  let(:role) { create(:project_role, permissions: %i[view_work_packages]) }
  let(:project) { create(:project, public: false) }
  let(:other) { create(:project, public: false) }
  let(:member) { create(:user, member_with_roles: { project => role }) }
  let!(:visible_wp) { create(:work_package, project:, subject: "Sichtbares Paket") }
  let!(:hidden_wp) { create(:work_package, project: other, subject: "Verstecktes Paket") }

  current_user { member }

  it "redirects #<id> to the work package" do
    get "/search", params: { q: "##{visible_wp.id}" }
    expect(response).to redirect_to("/work_packages/#{visible_wp.id}")
  end

  it "tolerates spaces around the input" do
    get "/search", params: { q: "  ##{visible_wp.id}  " }
    expect(response).to redirect_to("/work_packages/#{visible_wp.id}")
  end

  it "runs the normal search for an invisible id without a redirect or hint" do
    get "/search", params: { q: "##{hidden_wp.id}" }
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Verstecktes Paket")
  end

  it "runs the normal search for an unknown id" do
    get "/search", params: { q: "#999999999" }
    expect(response).to have_http_status(:ok)
  end

  it "leaves plain numbers and text to the normal search" do
    get "/search", params: { q: visible_wp.id.to_s }
    expect(response).to have_http_status(:ok)
    get "/search", params: { q: "#{visible_wp.id} Paket" }
    expect(response).to have_http_status(:ok)
  end
end
