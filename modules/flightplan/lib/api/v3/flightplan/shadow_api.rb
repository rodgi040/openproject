# frozen_string_literal: true

module API
  module V3
    module Flightplan
      # OP#1843: Auswertung der Schatten-Messung, nur für Admins. Schreiben gibt es hier nicht.
      class ShadowAPI < ::API::OpenProjectAPI
        resources :flightplan do
          resources :shadow do
            get :summary do
              raise API::Errors::Unauthorized unless current_user.admin?

              ::Flightplan::Shadow.summary
            end
          end
        end
      end
    end
  end
end
