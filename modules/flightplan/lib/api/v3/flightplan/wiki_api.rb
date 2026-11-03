# frozen_string_literal: true

module API
  module V3
    module Flightplan
      class WikiAPI < ::API::OpenProjectAPI
        resources :flightplan do
          resources :projects do
            route_param :id, type: String do
              resources :wiki do
                get do
                  pages = ::Flightplan::WikiPages.list(flightplan_project, current_user)
                  { pages: }
                rescue ::Flightplan::Error => error
                  flightplan_wiki_error!(error)
                end

                route_param :title, type: String do
                  get do
                    ::Flightplan::WikiPages.read(flightplan_project, params[:title], current_user)
                  rescue ::Flightplan::Error => error
                    flightplan_wiki_error!(error)
                  end

                  params do
                    requires :text, type: String
                  end
                  put do
                    ::Flightplan::WikiPages.write(
                      flightplan_project,
                      params[:title],
                      params[:text],
                      current_user
                    )
                  rescue ::Flightplan::Error => error
                    flightplan_wiki_error!(error)
                  end
                end
              end
            end
          end
        end

        helpers do
          def flightplan_project
            project = Project.find_by(identifier: params[:id]) || Project.find_by(id: params[:id])
            raise API::Errors::NotFound unless project
            raise API::Errors::NotFound unless project.visible?(current_user) || current_user.admin?

            project
          end

          def flightplan_wiki_error!(error)
            if error.message.include?("nicht sichtbar") || error.message.include?("nicht beschreibbar")
              raise API::Errors::Unauthorized
            end
            if error.message.include?("fehlt")
              raise API::Errors::NotFound
            end

            error!({ message: error.message }, 422)
          end
        end
      end
    end
  end
end
