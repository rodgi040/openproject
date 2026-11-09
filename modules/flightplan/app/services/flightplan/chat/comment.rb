# frozen_string_literal: true

module Flightplan
  module Chat
    # OP#1711 Wave 2: Eine Nachricht aus dem Chat-Thread wird Kommentar am Ticket, im Namen des angemeldeten Menschen
    # (dessen Session; der Agent-Token schreibt hier nie). Der Kommentar beginnt mit dem Marker "[aus Chat]". Er geht
    # durch AddWorkPackageNoteService, also durch Vertrag und Rechte des Menschen. Gespeichert heißt nicht zugestellt:
    # ein Agent sieht den Kommentar erst beim nächsten Lesen.
    class Comment
      MAX_LENGTH = 4000

      class Invalid < Error; end

      def self.call(user:, work_package:, text:)
        new(user:, work_package:, text:).call
      end

      def initialize(user:, work_package:, text:)
        @user = user
        @work_package = work_package
        @text = text.to_s.strip
      end

      def call
        raise Invalid, "Der Text fehlt" if @text.blank?
        raise Invalid, "Der Text ist zu lang (höchstens #{MAX_LENGTH} Zeichen)" if @text.length > MAX_LENGTH

        result = AddWorkPackageNoteService
          .new(user: @user, work_package: @work_package)
          .call("#{ChatEvents::MARKER} #{@text}", send_notifications: false)
        raise Error, "Kommentar fehlgeschlagen" unless result.success?

        result.result
      end
    end
  end
end
