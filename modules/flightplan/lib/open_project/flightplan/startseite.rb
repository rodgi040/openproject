# frozen_string_literal: true

module OpenProject
  module Flightplan
    # OP#1671: The home screen (/) shows signed-in users the ADA dashboard with the chat column instead of the
    # upstream blocks. Included into ::HomescreenController from the engine; the callback runs after the upstream
    # jump_to_module, so /?jump=… keeps working. Anonymous visitors keep the upstream page.
    module Startseite
      extend ActiveSupport::Concern

      included do
        before_action :flightplan_startseite, only: :index
      end

      private

      def flightplan_startseite
        return unless User.current.logged?

        if User.current.admin?
          @dashboard = ::Flightplan::Dashboard.load(user: User.current, params: params.permit(:bereich))
          @approval_state = ::Flightplan::Approvals.availability(User.current)
        end
        @board_widget = ::Flightplan::Board.load(user: User.current,
                                                 params: ::Flightplan::BoardController.widget_params(params))
        @questions_widget = ::Flightplan::QuestionsWidget.load(
          user: User.current, params: params.permit(::Flightplan::QuestionsWidget::PARAM),
          tree: @dashboard&.project_tree, status_order: @dashboard&.status_order
        )
        render "flightplan/dashboard/index"
      end
    end
  end
end
