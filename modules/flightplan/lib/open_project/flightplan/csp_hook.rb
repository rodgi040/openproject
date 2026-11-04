# frozen_string_literal: true

module OpenProject
  module Flightplan
    # OpenProject no longer applies the secure_headers gem. The live policy is
    # Rails' content security policy, extended per request the same way the
    # storages module extends connect-src.
    class CspHook < OpenProject::Hook::Listener
      CHAT_ORIGIN = "http://localhost:8092"

      def application_controller_before_action(context)
        context[:controller].append_content_security_policy_directives(
          frame_src: [CHAT_ORIGIN],
          # Der Arbeitsplatz und das Board prüfen den Chat vor dem Laden per fetch (no-cors, nur Erreichbarkeit).
          connect_src: [CHAT_ORIGIN],
          child_src: [CHAT_ORIGIN]
        )
      end
    end
  end
end
