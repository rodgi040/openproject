# frozen_string_literal: true

module Flightplan
  # Server-rendered ticket summary for the Arbeitsplatz page. Journals are the
  # only source for the timeline and the agent runs.
  class Workplace
    CHAT_ORIGIN = "http://localhost:8092"
    PREVIEW = 280
    COMMENT_LIMIT = 5
    START_STATUSES = ["In Arbeit", "Startfreigabe"].freeze
    CLAIM_NOTE = /\Aclaim\s+(\S+)/
    START_NOTE = /\Astart\b/i

    Page = Struct.new(
      :work_package, :subject, :status, :project_name, :project_identifier,
      :description, :description_full, :labels, :agent, :involved,
      :questions, :branch, :pull_request, :comments,
      :timeline, :tree, :progress, :runs, :context, :chat_questions,
      keyword_init: true
    )
    Person = Struct.new(:name, :group, keyword_init: true)
    Step = Struct.new(:at, :status, :user, keyword_init: true)
    Node = Struct.new(:id, :subject, :status, :role, keyword_init: true)
    Progress = Struct.new(:done, :total, :percent, keyword_init: true)
    Run = Struct.new(:at, :kind, :label, :user, keyword_init: true)
    Comment = Struct.new(:author, :text, :at, keyword_init: true)

    class << self
      include QuestionsHelper

      def load(user:, work_package:)
        new(user, work_package).load
      end
    end

    def initialize(user, work_package)
      @user = user
      @work_package = work_package
    end

    def load
      journals = @work_package.journals.includes(:user, :data, :customizable_journals).order(:version).to_a
      notes = comment_journals
      children = visible_children
      parent = visible_parent
      self.class::Page.new(
        work_package: @work_package,
        subject: @work_package.subject,
        status: @work_package.status.name,
        project_name: @work_package.project.name,
        project_identifier: @work_package.project.identifier,
        description: preview_text,
        description_full: full_text,
        labels: self.class.custom_list(@work_package, "Labels"),
        agent: agent_person,
        involved: involved_people,
        questions: open_questions,
        branch: branch_for(notes),
        pull_request: pull_request_for(notes),
        comments: notes.map { |journal| comment_for(journal) },
        timeline: timeline_for(journals),
        tree: tree_for(parent, children),
        progress: progress_for(children),
        runs: runs_for(journals),
        context: context_hash,
        chat_questions: Flightplan::ChatQuestions.items_from(open_questions)
      )
    end

    private

    def visible_children
      @work_package.children.merge(WorkPackage.visible(@user)).includes(:status).order(:id).to_a
    end

    def visible_parent
      parent = @work_package.parent
      return if parent.nil?
      return unless parent.visible?(@user)

      parent
    end

    def full_text
      @full_text ||= ActionController::Base.helpers.strip_tags(@work_package.description.to_s).squish
    end

    def preview_text
      full_text.truncate(PREVIEW)
    end

    def agent_person
      user = @work_package.assigned_to
      return if user.nil?

      Person.new(name: user.name, group: self.class.flightplan_agent_group(user))
    end

    def involved_people
      field = WorkPackageCustomField.find_by(name: "Beteiligte Agenten")
      return [] if field.nil?

      ids = @work_package.custom_values.where(custom_field_id: field.id).pluck(:value).filter_map do |value|
        Integer(value, exception: false)
      end
      User.where(id: ids).map { |user| Person.new(name: user.name, group: self.class.flightplan_agent_group(user)) }
    end

    def open_questions
      @open_questions ||= Flightplan::Question.open.where(work_package: @work_package).oldest_first.to_a
    end

    def comment_journals
      scope = @work_package.journals.where.not(notes: [nil, ""])
      scope = scope.where(internal: false) if Journal.column_names.include?("internal")
      scope.includes(:user).order(id: :desc).limit(COMMENT_LIMIT).reverse
    end

    def blob_for(notes)
      [full_text, self.class.custom_text(@work_package, "Pausenstand"), *notes.map(&:notes)].join("\n")
    end

    def branch_for(notes)
      blob_for(notes)[/(?:branch|Branch):\s*(\S+)/, 1]
    end

    def pull_request_for(notes)
      blob_for(notes)[/https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/\d+/]
    end

    def comment_for(journal)
      Comment.new(
        author: journal.user&.name,
        text: journal.notes.to_s.squish.truncate(240),
        at: journal.created_at
      )
    end

    def status_names
      @status_names ||= Status.pluck(:id, :name).to_h
    end

    def timeline_for(journals)
      previous = nil
      journals.filter_map do |journal|
        status_id = journal.data.try(:status_id)
        next if status_id.nil? || status_id == previous

        previous = status_id
        Step.new(at: journal.created_at, status: status_names[status_id], user: journal.user&.name)
      end
    end

    def tree_for(parent, children)
      nodes = []
      if parent
        nodes << Node.new(id: parent.id, subject: parent.subject, status: parent.status.name, role: "parent")
      end
      nodes << Node.new(id: @work_package.id, subject: @work_package.subject, status: @work_package.status.name, role: "self")
      children.each do |child|
        nodes << Node.new(id: child.id, subject: child.subject, status: child.status.name, role: "child")
      end
      nodes
    end

    def progress_for(children)
      total = children.size
      done = children.count { |child| child.status.is_closed? }
      percent = total.zero? ? 0 : ((done * 100.0) / total).round
      Progress.new(done:, total:, percent:)
    end

    def runs_for(journals)
      claim_field_id = WorkPackageCustomField.find_by(name: "Claim-Session")&.id
      previous_status = nil
      previous_claim = nil
      journals.flat_map do |journal|
        rows = []
        status_id = journal.data.try(:status_id)
        status_name = status_names[status_id]
        if previous_status && status_id && status_id != previous_status && START_STATUSES.include?(status_name)
          rows << Run.new(at: journal.created_at, kind: "start", label: status_name, user: journal.user&.name)
        end
        previous_status = status_id if status_id
        note = journal.notes.to_s.strip
        if (session = note[CLAIM_NOTE, 1])
          rows << Run.new(at: journal.created_at, kind: "claim", label: session, user: journal.user&.name)
        elsif note.match?(START_NOTE)
          rows << Run.new(at: journal.created_at, kind: "start", label: note, user: journal.user&.name)
        end
        if claim_field_id
          value = journal.customizable_journals.find { |row| row.custom_field_id == claim_field_id }&.value.to_s
          if value.present? && value != previous_claim && rows.none? { |row| row.kind == "claim" }
            rows << Run.new(at: journal.created_at, kind: "claim", label: value, user: journal.user&.name)
          end
          previous_claim = value if journal.customizable_journals.any? { |row| row.custom_field_id == claim_field_id }
        end
        rows
      end
    end

    def context_hash
      {
        id: @work_package.id,
        subject: @work_package.subject,
        project: @work_package.project.identifier,
        status: @work_package.status.name,
        labels: self.class.custom_list(@work_package, "Labels"),
        url: Rails.application.routes.url_helpers.work_package_path(@work_package),
        description: preview_text
      }
    end
  end
end
