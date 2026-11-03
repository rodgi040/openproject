# frozen_string_literal: true

module Flightplan
  class BoardController < ApplicationController
    before_action :require_login
    no_authorization_required! :index, :move

    layout "global"

    current_menu_item [:index, :move] do
      :flightplan
    end

    def index
      @board = Flightplan::Board.load(user: User.current, params: board_query)
      @chat_questions = Flightplan::ChatQuestions.items(User.current) if User.current.admin?
    end

    def move
      work_package = WorkPackage.visible(User.current).find(params[:id])
      Flightplan::Move.call(
        user: User.current,
        work_package:,
        column: params[:column],
        lock_version: params[:lock_version]
      )
      render json: { ok: true }
    rescue Flightplan::Error => error
      render json: { ok: false, error: error.message }, status: :unprocessable_entity
    rescue ActiveRecord::StaleObjectError
      render json: { ok: false, error: I18n.t("flightplan.board.conflict") }, status: :conflict
    end

    private

    def board_query
      params.permit(:q, :projects, :labels, :agents, :rejected, :done, limits: {})
    end
  end
end
