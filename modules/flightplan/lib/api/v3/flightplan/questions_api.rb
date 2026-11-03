# frozen_string_literal: true

module API
  module V3
    module Flightplan
      class QuestionsAPI < ::API::OpenProjectAPI
        resources :flightplan do
          resources :questions do
            params do
              requires :work_package_id, type: Integer
              requires :question, type: String
              optional :context, type: String
              optional :options, type: Array[String]
            end
            post do
              work_package = visible_work_package(params[:work_package_id])
              record = ::Flightplan::Questions::Create.call(
                user: current_user,
                work_package:,
                question: params[:question],
                context: params[:context],
                options: params[:options]
              )
              status 201
              ::Flightplan::QuestionPayload.dump(record)
            rescue ::Flightplan::Error => error
              flightplan_error!(error)
            end

            params do
              optional :status, type: String
              optional :project, type: String
              optional :author, type: String
            end
            get do
              { questions: filtered_questions.map { |question| ::Flightplan::QuestionPayload.dump(question) } }
            end

            route_param :id, type: Integer do
              params do
                optional :option, type: String
                optional :text, type: String
              end
              post :answer do
                question = ::Flightplan::Question.find_by(id: params[:id])
                raise API::Errors::NotFound unless question
                unless question.work_package.visible?(current_user) || current_user.admin?
                  raise API::Errors::NotFound
                end

                record = ::Flightplan::Questions::Answer.call(
                  user: current_user,
                  question:,
                  option: params[:option],
                  text: params[:text]
                )
                ::Flightplan::QuestionPayload.dump(record)
              rescue ::Flightplan::Error => error
                flightplan_error!(error)
              end
            end
          end
        end

        helpers do
          def filtered_questions
            scope = ::Flightplan::Question.oldest_first.includes(:author, :answered_by, work_package: :project)
            scope = scope.where(status: params[:status]) if params[:status].present?
            if params[:project].present?
              project = Project.find_by(identifier: params[:project]) || Project.find_by(id: params[:project])
              scope = scope.joins(:work_package).where(work_packages: { project_id: project&.id })
            end
            if params[:author].present?
              author = User.find_by(login: params[:author], type: "User")
              scope = scope.where(author_id: author&.id)
            end
            scope.select { |question| question.work_package.visible?(current_user) || current_user.admin? }
          end

          def visible_work_package(id)
            work_package = WorkPackage.visible(current_user).find_by(id:)
            work_package ||= WorkPackage.find_by(id:) if current_user.admin?
            raise API::Errors::NotFound unless work_package

            work_package
          end

          def flightplan_error!(error)
            raise API::Errors::Unauthorized if error.message.include?("vorbehalten")

            error!({ message: error.message }, 422)
          end
        end
      end

      class WorkPackageQuestionsAPI < ::API::OpenProjectAPI
        resources :flightplan do
          resources :questions do
            params do
              optional :status, type: String
            end
            get do
              work_package = WorkPackage.visible(current_user).find_by(id: params[:id])
              work_package ||= WorkPackage.find_by(id: params[:id]) if current_user.admin?
              raise API::Errors::NotFound unless work_package

              scope = ::Flightplan::Question.where(work_package_id: work_package.id).oldest_first
              scope = scope.where(status: params[:status]) if params[:status].present?
              { questions: scope.map { |question| ::Flightplan::QuestionPayload.dump(question) } }
            end
          end
        end
      end
    end
  end
end
