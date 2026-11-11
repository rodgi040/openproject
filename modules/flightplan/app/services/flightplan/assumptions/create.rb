# frozen_string_literal: true

module Flightplan
  module Assumptions
    # OP#1839: Ein Agent (oder Mensch) hält eine Annahme am Ticket fest. Kommentar „Annahme: …“, kein Statuswechsel.
    # Grenze: höchstens eine offene Annahme je Ticket.
    class Create
      def self.call(user:, work_package:, text:)
        new(user:, work_package:, text:).call
      end

      def initialize(user:, work_package:, text:)
        @user = user
        @work_package = work_package
        @text = text.to_s.strip
      end

      def call
        raise Error, "Text fehlt" if @text.blank?
        raise Error, "Text zu lang (höchstens #{Assumption::TEXT_LIMIT} Zeichen)" if @text.length > Assumption::TEXT_LIMIT
        raise Error, "Paket nicht sichtbar" unless @user.admin? || @work_package.visible?(@user)

        Assumption.transaction do
          @work_package.lock!
          raise Error, "Das Ticket hat schon eine offene Annahme" if Assumption.open.exists?(work_package_id: @work_package.id)

          record = Assumption.create!(work_package: @work_package, author: @user, text: @text, status: "open")
          result = AddWorkPackageNoteService
            .new(user: @user, work_package: @work_package)
            .call("Annahme: #{@text}", send_notifications: false)
          raise Error, "Kommentar zur Annahme fehlgeschlagen" unless result.success?

          record
        end
      end
    end
  end
end
