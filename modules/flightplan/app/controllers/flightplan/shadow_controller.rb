# frozen_string_literal: true

module Flightplan
  # OP#1843: Das Dashboard meldet, dass ein Mensch eine Chat-Frage mit empfohlener Option beantwortet hat. Die Zeile dient nur der
  # Messung (Flightplan::Shadow); nichts wird dadurch beantwortet oder entschieden. Nur Session und Rails-CSRF-Token, nie API-Token
  # oder Basic-Auth, nie ein Agent-Konto, und nur, wer auch eine Rückfrage beantworten darf (Questions::Answer.human?).
  class ShadowController < ApplicationController
    prepend_before_action :reject_api_credentials
    before_action :require_login
    before_action :reject_non_session_access
    no_authorization_required! :create

    FIELD_MAX = ShadowDecision::FIELD_MAX
    REQUEST_ID_MAX = ShadowDecision::REQUEST_ID_MAX

    def create
      work_package = WorkPackage.visible(User.current).find_by(id: positive_integer(params[:ticket]))
      return render(json: { ok: false }, status: :not_found) unless work_package
      return deny unless human?(work_package)

      fields = validated_fields
      return render(json: { ok: false, error: fields }, status: :unprocessable_entity) if fields.is_a?(String)

      record = Flightplan::Shadow.record_chat(work_package:, **fields)
      render json: { ok: true, recorded: record.present? }
    end

    private

    def human?(work_package)
      !Flightplan::Approvals.agent_user?(User.current) && Flightplan::Questions::Answer.human?(User.current, work_package)
    end

    # Hash mit request_id, recommended, chosen oder ein Fehlertext.
    def validated_fields
      request_id = text(params[:request_id])
      recommended = text(params[:recommended])
      chosen = text(params[:chosen])
      return "request_id fehlt oder ist zu lang" if request_id.blank? || request_id.length > REQUEST_ID_MAX
      return "recommended fehlt oder ist zu lang" if recommended.blank? || recommended.length > FIELD_MAX
      return "chosen fehlt oder ist zu lang" if chosen.blank? || chosen.length > FIELD_MAX

      { request_id:, recommended:, chosen: }
    end

    # Nur Zeichenketten; Hashes und Listen aus Parametern zählen als fehlend.
    def text(value)
      value.is_a?(String) ? value.strip : nil
    end

    def positive_integer(value)
      value.to_s.match?(/\A\d{1,9}\z/) ? value.to_i : 0
    end

    def deny
      render json: { ok: false, error: "Nicht erlaubt" }, status: :forbidden
    end

    def reject_api_credentials
      return unless request.authorization.present? || request.headers["X-Api-Key"].present? || params[:key].present?

      deny
    end

    def reject_non_session_access
      return unless User.current.logged?
      return if session[:user_id].to_s == User.current.id.to_s

      deny
    end
  end
end
