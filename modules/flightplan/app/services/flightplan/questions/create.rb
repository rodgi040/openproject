# frozen_string_literal: true

module Flightplan
  module Questions
    class Create
      def self.call(user:, work_package:, question:, context: nil, options: nil)
        new(user:, work_package:, question:, context:, options:).call
      end

      def initialize(user:, work_package:, question:, context:, options:)
        @user = user
        @work_package = work_package
        @question = question.to_s
        @context = context
        @options = Array(options).map(&:to_s)
      end

      def call
        raise Error, "Frage fehlt" if @question.blank?
        raise Error, "Paket nicht sichtbar" unless visible?

        Question.transaction do
          @work_package.lock!
          previous_id = remember_and_wait
          record = Question.create!(
            work_package: @work_package,
            author: @user,
            question: @question,
            context: @context.presence,
            options: @options,
            status: "open",
            previous_status_id: previous_id
          )
          notify(record)
          record
        end
      end

      private

      def visible?
        @user.admin? || @work_package.visible?(@user)
      end

      def remember_and_wait
        open = Question.open.where(work_package_id: @work_package.id).oldest_first
        return open.first.previous_status_id if open.any?

        previous_id = @work_package.status_id
        unless @work_package.status&.name == Question::WAITING_STATUS
          StatusChange.apply!(@work_package, StatusChange.waiting_status)
          @work_package.reload
        end
        previous_id
      end

      def notify(record)
        note = "Rückfrage:\n#{record.question}\n\nInbox: /flightplan/questions#q-#{record.id}"
        result = AddWorkPackageNoteService
          .new(user: @user, work_package: @work_package)
          .call(note, send_notifications: false)
        raise Error, "Kommentar zur Rückfrage fehlgeschlagen" unless result.success?

        journal = result.result
        recipients.each do |recipient|
          Notification.create!(
            recipient:,
            actor: @user,
            journal:,
            resource: @work_package,
            reason: :commented,
            subject: record.question.truncate(200),
            read_ian: false,
            mail_alert_sent: true,
            mail_reminder_sent: true
          )
        end
      end

      def recipients
        role = Role.find_by(name: "Mensch")
        humans = if role
          Member.where(project_id: @work_package.project_id, entity_type: nil)
            .joins(:roles)
            .where(roles: { id: role.id })
            .includes(:principal)
            .filter_map { |member| member.principal if member.principal.is_a?(User) }
        else
          []
        end
        admins = User.where(admin: true).select(&:active?)
        (humans + admins).uniq.select(&:active?) - [@user]
      end
    end
  end
end
