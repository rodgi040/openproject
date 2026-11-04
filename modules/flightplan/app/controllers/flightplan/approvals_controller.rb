# frozen_string_literal: true

module Flightplan
  # Startfreigabe (S8). Nur Admin, nur mit Session und Rails-CSRF-Token. Der Statuswechsel läuft als der
  # angemeldete Mensch durch WorkPackages::UpdateService. Kein Start-Label, kein Agent-Start.
  class ApprovalsController < ApplicationController
    prepend_before_action :reject_api_credentials, only: :create
    before_action :reject_non_session_access, only: :create
    before_action :require_admin
    before_action :reject_agent_user, only: :create
    no_authorization_required! :index, :create

    layout "global"

    current_menu_item [:index, :create] do
      :flightplan_dashboard
    end

    def index; end

    def create
      entries = selected_entries
      if entries.empty?
        flash[:alert] = t("flightplan.approvals.none")
      else
        flash_result(Flightplan::Approvals.call(user: User.current, entries:))
        Rails.cache.delete(["flightplan-dashboard", User.current.id])
      end
      redirect_to flightplan_dashboard_path(bereich: bereich_param)
    end

    private

    # Der Knopf einer Zeile sendet "single"; die Sammelfreigabe sendet die angehakten ids.
    def selected_entries
      locks = params[:lock_versions].respond_to?(:to_unsafe_h) ? params[:lock_versions].to_unsafe_h : {}
      ids = params[:single].present? ? [params[:single]] : Array(params[:ids])
      ids.filter_map { |id| id.is_a?(String) ? { id: id, lock_version: locks[id] } : nil }.uniq { |entry| entry[:id] }
    end

    def flash_result(result)
      reasons = result.rejected.first(10).map { |id, key| rejection_text(id, key) }.join("; ")
      if result.rejected_count.zero?
        flash[:notice] = t("flightplan.approvals.done", ok: result.ok_count, rejected: 0)
      else
        flash[:alert] = t("flightplan.approvals.done_with_reasons",
                          ok: result.ok_count, rejected: result.rejected_count, reasons:)
      end
    end

    def rejection_text(id, key)
      reason = key.is_a?(Symbol) ? t("flightplan.approvals.reasons.#{key}") : key.to_s.truncate(120)
      id ? "##{id.to_i} (#{reason})" : reason
    end

    def bereich_param
      key = params[:bereich].to_s
      Flightplan::Dashboard::BEREICHE.key?(key) ? key : nil
    end

    # API-Token, Basic-Auth und Schlüssel im Parameter sind hier nie zulässig (403), noch vor jeder Anmeldung.
    def reject_api_credentials
      return unless request.authorization.present? || request.headers["X-Api-Key"].present? || params[:key].present?

      render_403
    end

    # Wer angemeldet ist, muss aus der Session kommen: User.current stimmt mit session[:user_id] überein.
    def reject_non_session_access
      return unless User.current.logged?
      return if session[:user_id].to_s == User.current.id.to_s

      render_403
    end

    def reject_agent_user
      render_403 if Flightplan::Approvals.agent_user?(User.current)
    end
  end
end
