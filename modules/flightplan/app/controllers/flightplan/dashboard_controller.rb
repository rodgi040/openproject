# frozen_string_literal: true

module Flightplan
  # Nur lesend (H7). Nur Admin (OE1, F7): require_admin antwortet anonym mit Login-Weiterleitung, sonst 403.
  class DashboardController < ApplicationController
    before_action :require_admin
    no_authorization_required! :index

    layout "global"

    current_menu_item [:index] do
      :flightplan_dashboard
    end

    def index
      @dashboard = Flightplan::Dashboard.load(user: User.current, params: params.permit(:bereich))
      @approval_state = Flightplan::Approvals.availability(User.current)
    end
  end
end
