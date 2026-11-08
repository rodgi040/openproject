# frozen_string_literal: true

# #1618: remove Enterprise advertising (banners, teasers, trial/buy buttons, gem icons).
# Only presentation is touched. EnterpriseToken.allows_to? and the license service stay as they are,
# so gated features remain gated.
module OpenProject::Flightplan
  module NoUpsell
    module BannerRender
      def render?
        # Keep banners that report an already available (e.g. trial) feature out too: no advertising at all.
        false
      end
    end

    module ComponentOff
      def render?
        false
      end
    end

    module ButtonsOff
      private

      def buttons
        []
      end
    end

    module HideBanners
      def hide_banners?
        true
      end
    end

    module MenuItemNoGem
      def enterprise_feature_missing?
        false
      end
    end

    module TabsNoGem
      def render_tab_header_nav(header, tabs, test_selector: nil)
        super(header, tabs.map { |tab| tab.except(:enterprise_feature) }, test_selector:)
      end
    end

    module_function

    def apply!
      EnterpriseEdition::BannerComponent.prepend(BannerRender)
      EnterpriseEdition::UpsellButtonsComponent.prepend(ButtonsOff)
      EnterpriseEdition::BuyNowButtonComponent.prepend(ComponentOff)
      EnterpriseEdition::TrialTeaserComponent.prepend(ComponentOff)
      EnterpriseTrials::TrialButtonComponent.prepend(ComponentOff)
      EnterpriseTrials::BannerComponent.prepend(ComponentOff)
      EnterpriseToken.singleton_class.prepend(HideBanners)
      Redmine::MenuManager::MenuItem.prepend(MenuItemNoGem)
      TabsHelper.prepend(TabsNoGem)
      # Token page: same partial name, without the benefits/upsell block (view path wins over core).
      EnterpriseTokensController.prepend_view_path(
        OpenProject::Flightplan::Engine.root.join("app/views_override").to_s
      )
    end
  end
end
