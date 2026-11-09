# frozen_string_literal: true

module Flightplan
  # OP#1673: Die Rückfragen stehen im Widget „Rückfragen“ der Startseite. Die frühere Seite leitet dorthin um (mit
  # Vorauswahl des Projekts); ihre JSON-Liste und die Antwort-Route bleiben.
  class QuestionsController < ApplicationController
    before_action :require_login
    no_authorization_required! :index, :answer

    def index
      @project = find_project
      if request.format.json?
        render json: { items: Flightplan::ChatQuestions.items_from(question_scope.to_a) }
        return
      end

      redirect_to root_path(Flightplan::QuestionsWidget::PARAM => redirect_scope)
    end

    def answer
      question = visible_question(params[:id])
      Flightplan::Questions::Answer.call(
        user: User.current,
        question:,
        option: params[:option],
        text: params[:text]
      )
      # OP#1710: sichtbare Bestätigung mit gewählter Antwort und neuem Status (JSON für Dashboard-JS und Chat, sonst flash).
      summary = answer_summary(question)
      if request.format.json?
        render json: { ok: true, answer: summary, items: Flightplan::ChatQuestions.items(User.current) }
        return
      end

      nxt = question_scope.first
      redirect_to return_path(nxt ? "q-#{nxt.id}" : (User.current.admin? ? "fp-widget-attention" : "fp-widget-questions")),
                  notice: summary[:message]
    rescue Flightplan::Error => error
      if request.format.json?
        render json: { ok: false, error: error.message }, status: error_status(error)
        return
      end

      redirect_to return_path("q-#{params[:id]}"), alert: error.message
    end

    private

    # OP#1710: „Beantwortet: <Option/Freitext-Anfang> – #<id>, Status jetzt <Status>“.
    def answer_summary(question)
      work_package = question.work_package.reload
      given = question.chosen_option.presence || question.answer.to_s
      status = work_package.status&.name.to_s
      {
        id: question.id,
        work_package_id: work_package.id,
        option: question.chosen_option,
        text: question.answer,
        status:,
        message: t("flightplan.questions.answered_summary",
                   answer: given.squish.truncate(60), id: work_package.id, status: status.presence || "–")
      }
    end

    def error_status(error)
      case error
      when Flightplan::Questions::Answer::Forbidden then :forbidden
      when Flightplan::Questions::Answer::AlreadyAnswered then :conflict
      else :unprocessable_entity
      end
    end

    def find_project
      key = params[:project_id].presence || params[:project].presence
      return if key.blank?

      project = Project.find_by(identifier: key.to_s) || Project.find_by(id: key)
      raise ActiveRecord::RecordNotFound unless project
      raise ActiveRecord::RecordNotFound unless project.visible?(User.current) || User.current.admin?

      project
    end

    def selected_identifiers
      params[:projects].to_s.split(",").map(&:strip).compact_blank
    end

    def redirect_scope
      Flightplan::QuestionsWidget.scope_for(project: @project, identifiers: selected_identifiers)
    end

    def question_scope
      scope = Flightplan::Question
        .includes(:answered_by, author: :groups, work_package: %i[project status])
        .joins(:work_package)
        .merge(WorkPackage.visible(User.current))
        .oldest_first
      scope = scope.open unless params[:all] == "1" && request.format.json?
      if @project
        scope = scope.where(work_packages: { project_id: @project.id })
      elsif selected_identifiers.any?
        ids = Project.visible(User.current).where(identifier: selected_identifiers).select(:id)
        scope = scope.where(work_packages: { project_id: ids })
      end
      if params[:author].present?
        author = User.find_by(login: params[:author], type: "User")
        scope = scope.where(author_id: author&.id || 0)
      end
      scope
    end

    def visible_question(id)
      Flightplan::Question
        .joins(:work_package)
        .merge(WorkPackage.visible(User.current))
        .find(id)
    end

    # Zurück an die Stelle, von der das Formular kam. OP#1721: es gibt nur noch die Hauptseite; return_to=dashboard
    # (alte Formulare) führt ebenfalls dorthin.
    def return_path(anchor)
      root_path({ Flightplan::QuestionsWidget::PARAM => params[Flightplan::QuestionsWidget::PARAM].presence, anchor: }.compact)
    end
  end
end
