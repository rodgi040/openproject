# frozen_string_literal: true

module Flightplan
  class AssetsController < ApplicationController
    no_authorization_required! :javascript, :stylesheet

    # Rails marks every GET and then rejects a non-XHR JavaScript body.
    # A script tag does not send X-Requested-With, so the file would be a 500.
    skip_forgery_protection only: :javascript

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
