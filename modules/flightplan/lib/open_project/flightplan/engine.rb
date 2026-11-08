# frozen_string_literal: true

module OpenProject::Flightplan
  class Engine < ::Rails::Engine
    engine_name :openproject_flightplan

    include OpenProject::Plugins::ActsAsOpEngine

    register "openproject-flightplan",
             author_url: "https://github.com/rodgi040/openproject",
             bundled: true do
      menu :global_menu,
           :flightplan,
           { controller: "/flightplan/board", action: :index },
           caption: :"flightplan.label",
           after: :home,
           icon: :bookmark,
           if: Proc.new { User.current.logged? }

      menu :global_menu,
           :flightplan_dashboard,
           { controller: "/flightplan/dashboard", action: :index },
           caption: :"flightplan.dashboard.menu",
           after: :flightplan,
           icon: :graph,
           if: Proc.new { User.current.admin? }
    end

    add_api_endpoint "API::V3::Root" do
      mount ::API::V3::Flightplan::QuestionsAPI
      mount ::API::V3::Flightplan::WikiAPI
    end

    add_api_endpoint "API::V3::WorkPackages::WorkPackagesAPI", :id do
      mount ::API::V3::Flightplan::WorkPackageQuestionsAPI
    end

    replace_principal_references "Flightplan::Question" => %i[author_id answered_by_id]

    config.to_prepare do
      OpenProject::Flightplan::Hooks
      OpenProject::Flightplan::CspHook
      ::HomescreenController.include OpenProject::Flightplan::Startseite
      require "open_project/flightplan/no_upsell"
      OpenProject::Flightplan::NoUpsell.apply!
    end
  end
end
