# frozen_string_literal: true

module Flightplan
  module Questions
    class Answer
      def self.call(user:, question:, option: nil, text: nil)
        new(user:, question:, option:, text:).call
      end

      def initialize(user:, question:, option:, text:)
        @user = user
        @question = question
        @option = option.to_s.presence
        @text = text.to_s.presence
      end

      def call
        raise Error, "Antworten ist der Rolle Mensch oder einem Admin vorbehalten" unless allowed?
        raise Error, "Die Frage ist bereits beantwortet" unless @question.open?
        raise Error, "Option oder Freitext fehlt" if @option.blank? && @text.blank?
        if @option.present? && @question.options.any? && !@question.options.include?(@option)
          raise Error, "Option unbekannt"
        end

        Question.transaction do
          @question.lock!
          @question.update!(
            status: "answered",
            chosen_option: @option,
            answer: @text,
            answered_by: @user,
            answered_at: Time.current
          )
          comment!
          restore_status! if Question.open.where(work_package_id: @question.work_package_id).none?
          @question
        end
      end

      private

      def allowed?
        return true if @user.admin?

        role = Role.find_by(name: "Mensch")
        return false unless role

        Member.where(project_id: @question.work_package.project_id, user_id: @user.id, entity_type: nil)
          .joins(:member_roles)
          .exists?(member_roles: { role_id: role.id })
      end

      def comment!
        lines = ["Rückfrage von #{@question.author.login}:", "> #{@question.question}"]
        lines << "Option: #{@question.chosen_option}" if @question.chosen_option.present?
        lines << "Antwort: #{@question.answer}" if @question.answer.present?
        result = AddWorkPackageNoteService
          .new(user: @user, work_package: @question.work_package)
          .call(lines.join("\n"), send_notifications: false)
        raise Error, "Kommentar fehlgeschlagen" unless result.success?
      end

      def restore_status!
        status = @question.previous_status
        return unless status

        StatusChange.apply!(@question.work_package, status)
      end
    end
  end
end
