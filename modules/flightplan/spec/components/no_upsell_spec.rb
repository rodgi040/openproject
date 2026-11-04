# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

RSpec.describe "Flightplan: no Enterprise upsell (#1618)", type: :component do
  include ViewComponent::TestHelpers

  let(:admin) { create(:admin) }

  before { login_as(admin) }

  it "does not render the feature banner for a missing feature" do
    render_inline(EnterpriseEdition::BannerComponent.new(:internal_comments))
    expect(page.text).to be_blank
  end

  it "does not render buy, trial or teaser components" do
    [EnterpriseEdition::BuyNowButtonComponent.new,
     EnterpriseEdition::TrialTeaserComponent.new,
     EnterpriseTrials::TrialButtonComponent.new].each do |component|
      expect(component.render?).to be(false) if component.respond_to?(:render?)
      render_inline(component)
      expect(page.text).to be_blank
    end
  end

  it "renders no upsell buttons" do
    render_inline(EnterpriseEdition::UpsellButtonsComponent.new(:internal_comments))
    expect(page).to have_no_link
  end

  it "shows no gem on missing enterprise menu features" do
    item = Redmine::MenuManager::MenuItem.new(:x, "/", enterprise_feature: "define_custom_style")
    expect(item.enterprise_feature_missing?).to be(false)
  end

  it "keeps the license gate intact" do
    expect(EnterpriseToken.allows_to?(:internal_comments)).to be(false)
  end
end
