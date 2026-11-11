# frozen_string_literal: true

module API
  module V3
    module Flightplan
      # OP#1839: Annahmen eines Agenten am Ticket (Vertrag Phase 2a, Abschnitt 1).
      class AssumptionsAPI < ::API::OpenProjectAPI
        resources :flightplan do
          resources :assumptions do
            params do
              requires :work_package_id, type: Integer
              requires :text, type: String
            end
            post do
              work_package = visible_work_package(params[:work_package_id])
              record = ::Flightplan::Assumptions::Create.call(user: current_user, work_package:, text: params[:text])
              status 201
              ::Flightplan::AssumptionPayload.dump(record)
            rescue ::Flightplan::Error => error
              flightplan_error!(error)
            end

            route_param :id, type: Integer do
              params do
                requires :decision, type: String
                optional :note, type: String
              end
              post :decide do
                assumption = ::Flightplan::Assumption.find_by(id: params[:id])
                raise API::Errors::NotFound unless assumption
                unless assumption.work_package.visible?(current_user) || current_user.admin?
                  raise API::Errors::NotFound
                end

                record = ::Flightplan::Assumptions::Decide.call(
                  user: current_user, assumption:, decision: params[:decision], note: params[:note]
                )
                ::Flightplan::AssumptionPayload.dump(record)
              rescue ::Flightplan::Error => error
                flightplan_error!(error)
              end
            end
          end
        end

        helpers do
          def visible_work_package(id)
            work_package = WorkPackage.visible(current_user).find_by(id:)
            work_package ||= WorkPackage.find_by(id:) if current_user.admin?
            raise API::Errors::NotFound unless work_package

            work_package
          end

          def flightplan_error!(error)
            raise API::Errors::Unauthorized if error.is_a?(::Flightplan::Assumptions::Decide::Forbidden)

            error!({ message: error.message }, 422)
          end
        end
      end

      class WorkPackageAssumptionsAPI < ::API::OpenProjectAPI
        resources :flightplan do
          resources :assumptions do
            params do
              optional :status, type: String
            end
            get do
              work_package = WorkPackage.visible(current_user).find_by(id: params[:id])
              work_package ||= WorkPackage.find_by(id: params[:id]) if current_user.admin?
              raise API::Errors::NotFound unless work_package

              scope = ::Flightplan::Assumption.where(work_package_id: work_package.id).includes(:author, :decided_by).newest_first
              scope = scope.where(status: params[:status]) if params[:status].present?
              { assumptions: scope.map { |assumption| ::Flightplan::AssumptionPayload.dump(assumption) } }
            end
          end
        end
      end
    end
  end
end
