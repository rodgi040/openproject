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

  describe "#1629 enterprise gem selector" do
    let(:gem_menu_sel) { 'a.op-menu--item-action[href$="/admin/enterprise_tokens"] > svg.octicon-op-enterprise-addons' }
    let(:gem_tile_sel) { 'a.menu-block[href$="/admin/enterprise_tokens"] > svg.octicon-op-enterprise-addons' }

    it "narrows the CSS rule to the gem glyph of the menu entry and the admin tile" do
      css = File.read(File.expand_path("../../app/assets/flightplan/flightplan.css", __dir__))

      expect(css).not_to include('a[href*="/admin/enterprise"]')
      rule = "#{Regexp.escape(gem_menu_sel)},\\s*#{Regexp.escape(gem_tile_sel)}\\s*\\{\\s*display: none !important;\\s*\\}"
      expect(css).to match(Regexp.new(rule))
    end

    it "renders the gem in the menu entry and keeps the token plus button outside the gem selectors" do
      get "/admin/enterprise_tokens"

      html = Capybara.string(response.body)
      expect(html).to have_css(gem_menu_sel, count: 1)
      expect(html).to have_css('a[href$="/admin/enterprise_tokens/new"] svg.octicon-plus')
      expect(html).not_to have_css('a[href$="/admin/enterprise_tokens/new"] svg.octicon-op-enterprise-addons')
    end

    it "renders the gem in the admin overview tile" do
      get "/admin"

      expect(Capybara.string(response.body)).to have_css(gem_tile_sel, count: 1)
    end
  end
end
