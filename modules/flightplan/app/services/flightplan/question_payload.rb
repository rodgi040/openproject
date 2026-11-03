# frozen_string_literal: true

module Flightplan
  module QuestionPayload
    module_function

    def dump(question)
      {
        id: question.id,
        work_package_id: question.work_package_id,
        author: question.author.login,
        question: question.question,
        context: question.context,
        options: question.options,
        status: question.status,
        answer: question.answer,
        chosen_option: question.chosen_option,
        answered_by: question.answered_by&.login,
        answered_at: question.answered_at&.iso8601,
        created_at: question.created_at&.iso8601
      }.tap do |payload|
        payload[:status_restored] = question.status_restored unless question.status_restored.nil?
      end
    end
  end
end
