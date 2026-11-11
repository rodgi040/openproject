# frozen_string_literal: true

module Flightplan
  module Questions
    class Create
      # OP#1842: kind, recommended, reversible und consequence sind optional und nullbar (Vertrag Phase 3, Abschnitt 4).
      def self.call(user:, work_package:, question:, context: nil, options: nil, kind: nil, recommended: nil,
                    reversible: nil, consequence: nil)
        new(user:, work_package:, question:, context:, options:, kind:, recommended:, reversible:, consequence:).call
      end

      def initialize(user:, work_package:, question:, context:, options:, kind: nil, recommended: nil, reversible: nil,
                     consequence: nil)
        @user = user
        @work_package = work_package
        @question = question.to_s
        @context = context
        @options = Array(options).map(&:to_s)
        @kind = kind.to_s.strip.presence
        @recommended = recommended.to_s.strip.presence
        @reversible = reversible
        @consequence = consequence.to_s.strip.presence
      end

      def call
        raise Error, "Frage fehlt" if @question.blank?
        validate_structure!
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
            kind: @kind,
            recommended_option: @recommended,
            reversible: parsed_reversible,
            consequence: @consequence,
            status: "open",
            previous_status_id: previous_id
          )
          notify(record)
          record
        end
      end

      private

      # 422 statt Datenbankfehler: unbekannte Art, Empfehlung außerhalb der Optionen, zu lange Folge, unlesbarer Wahrheitswert.
      def validate_structure!
        raise Error, "Art unbekannt (erlaubt: #{Question::KINDS.join(', ')})" if @kind && Question::KINDS.exclude?(@kind)
        if @recommended && @options.exclude?(@recommended)
          raise Error, "Empfehlung ist keine der Optionen"
        end
        if @consequence && @consequence.length > Question::CONSEQUENCE_MAX
          raise Error, "Folge ist länger als #{Question::CONSEQUENCE_MAX} Zeichen"
        end

        parsed_reversible
      end

      def parsed_reversible
        case @reversible
        when nil, "" then nil
        when true, "true" then true
        when false, "false" then false
        else raise Error, "umkehrbar muss wahr oder falsch sein"
        end
      end

      def visible?
        @user.admin? || @work_package.visible?(@user)
      end

      def remember_and_wait
        open = Question.open.where(work_package_id: @work_package.id).oldest_first
        return open.first.previous_status_id if open.any?

        # Schon „Wartet auf Mensch“ und keine offene Frage: es gibt keinen
        # gemerkten Vorgänger. Die Wiederherstellung bleibt aus.
        return if @work_package.status&.name == Question::WAITING_STATUS

        previous_id = @work_package.status_id
        StatusChange.apply!(@work_package, StatusChange.waiting_status)
        @work_package.reload
        previous_id
      end

      def notify(record)
        note = "Rückfrage:\n#{record.question}\n\nInbox: /#q-#{record.id}"
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
