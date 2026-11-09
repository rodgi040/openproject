# frozen_string_literal: true

module Flightplan
  # OP#1721: Das ADA-Dashboard ist die Hauptseite (/). Die alte Adresse /flightplan/dashboard leitet dorthin um und behält
  # die Query-Parameter (bereich, board[…], rueckfragen). Weiter nur Admin (OE1, F7): require_admin antwortet anonym mit
  # Login-Weiterleitung, sonst 403.
  class DashboardController < ApplicationController
    before_action :require_admin
    no_authorization_required! :index

    layout "global"

    current_menu_item [:index] do
      :home
    end

    def index
      query = request.query_parameters
      redirect_to query.empty? ? root_path : root_path(query)
    end
  end
end
