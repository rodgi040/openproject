# frozen_string_literal: true

module Flightplan
  # OP#1711 Wave 2: Verlauf und Kommentar für den Chat-Thread der Startseite. Nur JSON.
  #
  # events: liest Kommentare, Statuswechsel und Rückfragen eines sichtbaren Tickets (nur Admin, Session).
  # comment: schreibt einen Kommentar mit Marker "[aus Chat]" im Namen des angemeldeten Menschen. Wie die Startfreigabe
  # nur mit Session und Rails-CSRF-Token, nur Admin UND Login in FLIGHTPLAN_HUMAN_LOGINS (fail-closed), nie mit
  # API-Token oder Basic-Auth, nie als Agent-Konto. Der Agent-Token kann darüber nichts schreiben.
  class ChatController < ApplicationController
    prepend_before_action :reject_api_credentials, only: :comment
    before_action :require_login
    before_action :reject_non_session_access, only: :comment
    before_action :require_admin_json
    before_action :reject_agent_user, only: :comment
    before_action :reject_non_human, only: :comment
    no_authorization_required! :events, :comment

    def events
      work_package = visible_work_package
      payload = Flightplan::ChatEvents.load(
        user: User.current, work_package:,
        after_journal: params[:after], after_question: params[:after_question]
      )
      render json: payload.merge(ok: true, work_package_id: work_package.id)
    end

    def comment
      work_package = visible_work_package
      journal = Flightplan::Chat::Comment.call(user: User.current, work_package:, text: params[:text])
      render json: { ok: true, work_package_id: work_package.id, event_id: "c#{journal.id}",
                     message: t("flightplan.chat.saved_as_comment", id: work_package.id) }
    rescue Flightplan::Chat::Comment::Invalid => error
      render json: { ok: false, error: error.message }, status: :unprocessable_entity
    rescue Flightplan::Error => error
      render json: { ok: false, error: error.message }, status: :unprocessable_entity
    end

    private

    def visible_work_package
      WorkPackage.visible(User.current).find(params[:wp])
    end

    def deny(message = "Nicht erlaubt")
      render json: { ok: false, error: message }, status: :forbidden
    end

    def require_admin_json
      deny unless User.current.admin?
    end

    # API-Token, Basic-Auth und Schlüssel im Parameter sind hier nie zulässig (403), noch vor jeder Anmeldung.
    def reject_api_credentials
      return unless request.authorization.present? || request.headers["X-Api-Key"].present? || params[:key].present?

      deny
    end

    # Wer angemeldet ist, muss aus der Session kommen: User.current stimmt mit session[:user_id] überein.
    def reject_non_session_access
      return unless User.current.logged?
      return if session[:user_id].to_s == User.current.id.to_s

      deny
    end

    def reject_agent_user
      deny if Flightplan::Approvals.agent_user?(User.current)
    end

    # Allowlist wie bei der Startfreigabe: ein Admin ohne Eintrag in FLIGHTPLAN_HUMAN_LOGINS schreibt nicht.
    def reject_non_human
      deny unless Flightplan::Approvals.human?(User.current)
    end
  end
end
