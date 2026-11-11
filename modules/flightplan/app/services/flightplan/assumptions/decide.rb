# frozen_string_literal: true

module Flightplan
  module Assumptions
    # OP#1839: Nur der Mensch (Admin oder Rolle „Mensch“, dieselbe Prüfung wie beim Beantworten einer Rückfrage)
    # bestätigt oder verwirft eine Annahme. Verwerfen verlangt einen Text.
    class Decide
      class Forbidden < Error; end
      class AlreadyDecided < Error; end

      DECISIONS = { "confirmed" => "Annahme bestätigt", "rejected" => "Annahme verworfen" }.freeze

      def self.call(user:, assumption:, decision:, note: nil)
        new(user:, assumption:, decision:, note:).call
      end

      def initialize(user:, assumption:, decision:, note:)
        @user = user
        @assumption = assumption
        @decision = decision.to_s
        @note = note.to_s.strip.presence
      end

      def call
        raise Forbidden, "Entscheiden ist der Rolle Mensch oder einem Admin vorbehalten" unless allowed?
        raise Error, "Entscheidung unbekannt" unless DECISIONS.key?(@decision)
        raise Error, "Zum Verwerfen fehlt der Text" if @decision == "rejected" && @note.blank?
        raise Error, "Hinweis zu lang (höchstens #{Assumption::TEXT_LIMIT} Zeichen)" if @note.to_s.length > Assumption::TEXT_LIMIT

        Assumption.transaction do
          @assumption.lock!
          raise AlreadyDecided, "Die Annahme ist bereits entschieden" unless @assumption.open?

          @assumption.update!(status: @decision, decided_by: @user, decided_at: Time.current,
                              note: (@note if @decision == "rejected"))
          comment!
        end
        @assumption
      end

      private

      def allowed?
        Questions::Answer.human?(@user, @assumption.work_package)
      end

      def comment!
        line = DECISIONS.fetch(@decision)
        line = "#{line}: #{@note}" if @decision == "rejected"
        result = AddWorkPackageNoteService
          .new(user: @user, work_package: @assumption.work_package)
          .call(line, send_notifications: false)
        raise Error, "Kommentar fehlgeschlagen" unless result.success?
      end
    end
  end
end
