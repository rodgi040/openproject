# frozen_string_literal: true

module OpenProject
  module Flightplan
    # OP#1706: Dashboard und Board zeigen Pakete als `#<id>`. Die globale Suche (/search?q=%23123) springt bei genau
    # dieser Eingabe, optional mit Leerzeichen drumherum, direkt auf das Arbeitspaket. Nur wenn das Paket für den
    # aktuellen Nutzer sichtbar ist; sonst läuft die normale Suche weiter, ohne Hinweis, ob die Id existiert.
    # Included into ::SearchController from the engine; the callback runs after the upstream project authorization.
    module SucheNachId
      extend ActiveSupport::Concern

      ID_QUERY = /\A\s*#\s*(\d{1,9})\s*\z/

      included do
        before_action :flightplan_springe_zur_id, only: :index
      end

      private

      def flightplan_springe_zur_id
        match = ID_QUERY.match(params[:q].to_s)
        return unless match

        id = match[1].to_i
        redirect_to work_package_path(id) if WorkPackage.visible(User.current).exists?(id:)
      end
    end
  end
end
