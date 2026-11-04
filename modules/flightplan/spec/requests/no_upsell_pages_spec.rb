# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

RSpec.describe "Flightplan: no Enterprise upsell pages (#1618)", :skip_csrf, type: :rails_request do
  let(:admin) { create(:admin) }

  before { login_as(admin) }

  it "keeps token entry on the Enterprise page but drops benefits, trial and buy blocks" do
    get "/admin/enterprise_tokens"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("op-primer-flex-layout").or include("enterprise_token")
    expect(response.body).not_to include("upsell-benefits")
    expect(response.body).not_to include("info-boxes")
    expect(response.body).not_to include("chargebee")
    expect(response.body).not_to include("op-enterprise-banner")
  end

  it "renders no upsell banner on the project internal comments settings" do
    project = create(:project)
    get "/projects/#{project.identifier}/settings/work_packages/internal_comments"

    expect(response.body).not_to include("op-enterprise-banner")
  end

  it "does not render the share upsell banner" do
    project = create(:project)
    get "/projects/#{project.identifier}/work_packages/share_upsell"

    expect(response.body).not_to include("op-enterprise-banner")
  end
end
