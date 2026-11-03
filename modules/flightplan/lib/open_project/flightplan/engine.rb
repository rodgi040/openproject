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
           { controller: "/flightplan/home", action: :show },
           caption: :"flightplan.label",
           after: :home,
           icon: :bookmark,
           if: Proc.new { User.current.logged? }
    end
  end
end
