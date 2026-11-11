# frozen_string_literal: true

module Flightplan
  # OP#1843: Schatten-Messung (Vertrag Phase 3, Abschnitt 5). Das Modul PROTOKOLLIERT nur, was ein Mensch auf eine Frage mit
  # Empfehlung geantwortet hat, und daneben, was die Regel SHADOW_RULE_V1 getan hätte. Es gibt keinen Weg, der eine Frage ohne
  # Menschen beantwortet, und keinen Schalter dafür. Aufrufer: Questions::Answer (source ask, nach menschlicher Antwort) und
  # ShadowController (source chat, Session, CSRF, Mensch).
  module Shadow
    FREE_TEXT = "<Freitext>"

    module_function

    # Rückfrage über fp-op ask, vom Menschen beantwortet. Ohne Empfehlung entsteht keine Zeile.
    def record_ask(question)
      return if question.recommended_option.blank?

      chosen = question.chosen_option.presence
      verdict = ShadowRule.call(
        source: "ask", kind: question.kind, reversible: question.reversible, recommended: question.recommended_option,
        texts: [question.question, question.options, question.context]
      )
      ShadowDecision.create!(
        source: "ask", work_package_id: question.work_package_id, question_id: question.id, kind: question.kind,
        reversible: question.reversible, recommended: question.recommended_option, chosen: chosen || FREE_TEXT,
        matched: !chosen.nil? && chosen == question.recommended_option,
        would_auto: verdict.would_auto, rule: verdict.reason
      )
    rescue StandardError => error
      # Die Messung darf die Antwort des Menschen nie verhindern.
      Rails.logger.error("[flightplan] Schatten-Messung (ask) fehlgeschlagen: #{error.class}: #{error.message}")
      nil
    end

    # Chat-Frage, vom Menschen im Dashboard beantwortet. Ein zweiter Aufruf mit derselben request_id ändert nichts (nil).
    def record_chat(work_package:, request_id:, recommended:, chosen:)
      return if ShadowDecision.exists?(source: "chat", request_id:, work_package_id: work_package.id)

      verdict = ShadowRule.call(source: "chat", kind: nil, reversible: nil, recommended:)
      ShadowDecision.create!(
        source: "chat", work_package_id: work_package.id, request_id:, recommended:, chosen:,
        matched: chosen == recommended, would_auto: verdict.would_auto, rule: verdict.reason
      )
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    # „Schatten: N Fälle, davon M wie empfohlen; Regel hätte K-mal entschieden, davon F falsch“. „falsch“ = would_auto und
    # nicht matched.
    def summary
      scope = ShadowDecision.all
      {
        total: scope.count,
        matched: scope.where(matched: true).count,
        would_auto: scope.where(would_auto: true).count,
        wrong: scope.where(would_auto: true, matched: false).count,
        by_source: scope.group(:source).count,
        rule: ShadowRule::VERSION
      }
    end
  end
end
