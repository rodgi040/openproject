# frozen_string_literal: true

module Flightplan
  # OP#1674: Die Seite „Flightplan“ ist im ADA-Dashboard aufgegangen.
  class HomeController < ApplicationController
    before_action :require_login

    no_authorization_required! :show

    def show
      redirect_to main_app.root_path(anchor: "fp-widget-board")
    end
  end
end
