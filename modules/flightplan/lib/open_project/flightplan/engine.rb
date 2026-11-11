# frozen_string_literal: true

module OpenProject::Flightplan
  class Engine < ::Rails::Engine
    engine_name :openproject_flightplan

    include OpenProject::Plugins::ActsAsOpEngine

    register "openproject-flightplan",
             author_url: "https://github.com/rodgi040/openproject",
             bundled: true do
      # OP#1674: kein Eintrag „Flightplan“ mehr; das Board ist ein Widget der Startseite.
      # OP#1721: auch kein Eintrag „ADA Dashboard“ mehr; die Hauptseite (/) ist die eine Seite.
    end

    add_api_endpoint "API::V3::Root" do
      mount ::API::V3::Flightplan::QuestionsAPI
      mount ::API::V3::Flightplan::AssumptionsAPI
      mount ::API::V3::Flightplan::WikiAPI
      mount ::API::V3::Flightplan::ShadowAPI
    end

    add_api_endpoint "API::V3::WorkPackages::WorkPackagesAPI", :id do
      mount ::API::V3::Flightplan::WorkPackageQuestionsAPI
      mount ::API::V3::Flightplan::WorkPackageAssumptionsAPI
    end

    replace_principal_references "Flightplan::Question" => %i[author_id answered_by_id],
                                  "Flightplan::Assumption" => %i[author_id decided_by_id]

    config.to_prepare do
      OpenProject::Flightplan::Hooks
      OpenProject::Flightplan::CspHook
      ::HomescreenController.include OpenProject::Flightplan::Startseite
      ::SearchController.include OpenProject::Flightplan::SucheNachId
      require "open_project/flightplan/no_upsell"
      OpenProject::Flightplan::NoUpsell.apply!
    end
  end
end
