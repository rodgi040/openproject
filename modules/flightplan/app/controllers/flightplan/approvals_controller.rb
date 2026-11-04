# frozen_string_literal: true

module Flightplan
  # Andockpunkt für S8 (Freigabeknopf, Sammelfreigabe). Leer, ohne Schreibaktion.
  class ApprovalsController < ApplicationController
    before_action :require_admin
    no_authorization_required! :index

    layout "global"

    current_menu_item [:index] do
      :flightplan_dashboard
    end

    def index; end
  end
end
