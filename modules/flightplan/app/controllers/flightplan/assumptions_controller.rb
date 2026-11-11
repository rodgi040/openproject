# frozen_string_literal: true

module Flightplan
  # OP#1839: Der Mensch bestätigt oder verwirft eine Annahme auf der Abnahmekarte (Session und Rails-CSRF-Token, wie die
  # Antwort auf eine Rückfrage). Die Prüfung „nur Mensch“ steckt in Assumptions::Decide.
  class AssumptionsController < ApplicationController
    before_action :require_login
    no_authorization_required! :decide

    def decide
      assumption = visible_assumption(params[:id])
      Flightplan::Assumptions::Decide.call(
        user: User.current, assumption:, decision: params[:decision], note: params[:note]
      )
      Rails.cache.delete(Flightplan::Dashboard.cache_key(User.current.id))
      message = t("flightplan.acceptance.decided.#{assumption.status}", id: assumption.work_package_id)
      if request.format.json?
        render json: { ok: true, message:, assumption: assumption_json(assumption),
                       remaining_open: Flightplan::Assumption.open.where(work_package_id: assumption.work_package_id).count }
        return
      end

      redirect_to root_path(anchor: "fp-inbox"), notice: message
    rescue Flightplan::Error => error
      if request.format.json?
        render json: { ok: false, error: error.message }, status: error_status(error)
        return
      end

      redirect_to root_path(anchor: "fp-inbox"), alert: error.message
    end

    private

    def assumption_json(assumption)
      Flightplan::AssumptionPayload.dump(assumption).merge(ticket: assumption.work_package_id)
    end

    def error_status(error)
      error.is_a?(Flightplan::Assumptions::Decide::Forbidden) ? :forbidden : :unprocessable_entity
    end

    def visible_assumption(id)
      Flightplan::Assumption
        .joins(:work_package)
        .merge(WorkPackage.visible(User.current))
        .find(id)
    end
  end
end
