# frozen_string_literal: true

module Flightplan
  class ChatQuestions
    class << self
      include QuestionsHelper

      def items(user)
        scope = Question
          .open
          .includes(:author, work_package: %i[project status])
          .joins(:work_package)
          .merge(WorkPackage.visible(user))
          .oldest_first
          .limit(30)
        items_from(scope)
      end

      def items_from(questions)
        questions.map { |question| item(question) }
      end

      def item(question, context: nil)
        work_package = question.work_package
        context ||= flightplan_card_context(question)
        {
          id: question.id,
          question: question.question,
          context: question.context,
          options: question.options,
          work_package_id: work_package.id,
          subject: work_package.subject,
          project: work_package.project.identifier,
          status: work_package.status.name,
          url: Rails.application.routes.url_helpers.work_package_path(work_package),
          description: context[:description],
          pause: context[:pause],
          branch: context[:branch],
          pull_request: context[:pull_request],
          labels: context[:labels],
          comments: context[:comments]
        }
      end

      def strip_tags(text)
        ActionController::Base.helpers.strip_tags(text.to_s)
      end
    end
  end
end
