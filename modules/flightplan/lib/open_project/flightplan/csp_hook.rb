# frozen_string_literal: true

module OpenProject
  module Flightplan
    # OpenProject no longer applies the secure_headers gem. The live policy is
    # Rails' content security policy, extended per request the same way the
    # storages module extends connect-src.
    class CspHook < OpenProject::Hook::Listener
      CHAT_ORIGIN = "http://localhost:8092"

      def application_controller_before_action(context)
        controller = context[:controller]
        directives = { frame_src: [CHAT_ORIGIN], child_src: [CHAT_ORIGIN] }
        # Arbeitsplatz, Board und Startseite (OP#1671) prüfen den Chat vor dem Laden per fetch (no-cors, nur Erreichbarkeit).
        # connect-src nur auf den Controllern des Moduls und der Startseite, nicht auf jeder OpenProject-Seite.
        directives[:connect_src] = [CHAT_ORIGIN] if chat_page?(controller)
        controller.append_content_security_policy_directives(**directives)
      end

      private

      def chat_page?(controller)
        controller.class.name.to_s.start_with?("Flightplan::") || controller.is_a?(::HomescreenController)
      end
    end
  end
end
