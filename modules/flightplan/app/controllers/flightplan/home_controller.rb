# frozen_string_literal: true

module Flightplan
  class HomeController < ApplicationController
    before_action :require_login

    no_authorization_required! :show

    layout "global"

    current_menu_item [:show] do
      :flightplan
    end

    def show
      redirect_to flightplan_board_path
    end
  end
end
