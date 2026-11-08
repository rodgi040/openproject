# frozen_string_literal: true

module Flightplan
  # OP#1674: Das Board ist ein Widget des ADA-Dashboards. GET /flightplan/board leitet mit seiner Auswahl dorthin um
  # (?board[...]); die Move-Route bleibt.
  class BoardController < ApplicationController
    PARAMS = [:q, :projects, :bereich, :labels, :agents, :rejected, :done, { limits: {} }].freeze

    before_action :require_login
    no_authorization_required! :index, :move

    def self.widget_params(params)
      raw = params[:board]
      raw.respond_to?(:permit) ? raw.permit(*PARAMS) : {}
    end

    def index
      query = params.slice(*PARAMS.grep(Symbol), :limits).permit(*PARAMS).to_h.compact_blank
      redirect_to main_app.root_path(board: query.presence, anchor: "fp-widget-board")
    end

    def move
      work_package = WorkPackage.visible(User.current).find(params[:id])
      moved = Flightplan::Move.call(
        user: User.current,
        work_package:,
        column: params[:column],
        lock_version: params[:lock_version]
      )
      render json: { ok: true, lock_version: moved.lock_version,
                     column: Flightplan::Board.new(User.current, {}).column_for(moved) }
    rescue Flightplan::Error => error
      render json: { ok: false, error: error.message }, status: :unprocessable_entity
    rescue ActiveRecord::StaleObjectError
      render json: { ok: false, error: I18n.t("flightplan.board.conflict") }, status: :conflict
    end
  end
end
