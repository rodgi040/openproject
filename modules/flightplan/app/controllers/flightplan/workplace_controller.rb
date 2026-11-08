# frozen_string_literal: true

module Flightplan
  class WorkplaceController < ApplicationController
    before_action :require_login
    no_authorization_required! :show

    layout "global"

    def show
      work_package = WorkPackage.visible(User.current).find(params[:id])
      @place = Flightplan::Workplace.load(user: User.current, work_package:)
    end
  end
end
