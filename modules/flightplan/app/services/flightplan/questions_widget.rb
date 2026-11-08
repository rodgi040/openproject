# frozen_string_literal: true

module Flightplan
  # OP#1673: Widget „Rückfragen“ der Startseite (/ und /flightplan/dashboard), Ersatz der Seite /flightplan/questions.
  # Offene Rückfragen zu Arbeitspaketen, die der Nutzer sehen darf, älteste zuerst, gruppiert nach Bereich. Nicht im
  # Dashboard-Cache: eine beantwortete Frage verschwindet mit dem nächsten Seitenaufruf.
  class QuestionsWidget
    LIMIT = 100
    CHAT_LIMIT = 30
    PARAM = "rueckfragen"
    ALL = "alle"

    def self.load(user:, params: {}, tree: nil, status_order: nil, now: Time.current)
      new(user:, params:, tree:, status_order:, now:).load
    end

    # Wert für den Parameter PARAM aus den Parametern der alten Seite (project, projects, project_id).
    def self.scope_for(project: nil, identifiers: [])
      return "project:#{project.identifier}" if project
      return "project:#{identifiers.first}" if identifiers.one?

      ALL
    end

    attr_reader :rows, :tree, :status_order, :chat_items

    def initialize(user:, params:, tree:, status_order:, now:)
      @user = user
      @raw = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @tree = tree
      @status_order = status_order
      @now = now
    end

    def load
      questions = Question.open
        .includes(author: :groups, work_package: %i[project status])
        .joins(:work_package)
        .merge(WorkPackage.visible(@user))
        .oldest_first
        .limit(LIMIT)
        .to_a
      @tree ||= Dashboard.project_tree(@user)
      @status_order ||= Status.order(:position).pluck(:name)
      labels = Dashboard.work_package_labels(@user, questions.map(&:work_package_id).uniq)
      @rows = questions.map { |question| row_for(question, labels) }
      @chat_items = @rows.first(CHAT_LIMIT).map { |row| ChatQuestions.item(row[:question], context: row[:context]) }
      self
    end

    def count
      @rows.size
    end

    # Vorauswahl im Projekt-/Bereichsfilter (Werte wie in WidgetFilters#scopes), nil für alle.
    def selected_scope
      value = @raw[PARAM].to_s.strip
      value.match?(/\A(project|bereich):.+\z/) ? value.truncate(120) : nil
    end

    def groups
      (Dashboard::BEREICHE.values + [Dashboard::NO_BEREICH]).filter_map do |label|
        rows = @rows.select { |row| row[:bereich] == label }
        { label:, rows: } if rows.any?
      end
    end

    private

    def projects
      @projects ||= @tree.index_by { |entry| entry[:identifier] }
    end

    def row_for(question, labels)
      work_package = question.work_package
      project = work_package.project
      entry = projects[project.identifier]
      {
        id: question.id, question:, text: question.question, context_text: question.context, options: question.options,
        work_package_id: work_package.id, subject: work_package.subject, status: work_package.status.name,
        project: project.name, project_path: entry ? entry[:path] : [project.identifier],
        bereich: entry&.dig(:bereich) || Dashboard::NO_BEREICH, labels: labels[work_package.id] || [],
        agent: question.author&.name, agent_group: ChatQuestions.flightplan_agent_group(question.author),
        since: question.created_at, age_seconds: [(@now - question.created_at).to_i, 0].max,
        context: ChatQuestions.flightplan_card_context(question)
      }
    end
  end
end
