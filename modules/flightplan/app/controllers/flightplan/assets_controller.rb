# frozen_string_literal: true

module Flightplan
  class AssetsController < ApplicationController
    no_authorization_required! :javascript, :stylesheet

    def javascript
      send_module_file("flightplan.js", "text/javascript")
    end

    def stylesheet
      send_module_file("flightplan.css", "text/css")
    end

    private

    def send_module_file(name, type)
      path = OpenProject::Flightplan::Engine.root.join("app/assets/flightplan", name)
      response.headers["Cache-Control"] = "no-cache"
      send_file path, type:, disposition: "inline"
    end
  end
end
