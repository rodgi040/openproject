# frozen_string_literal: true

module Flightplan
  class QuestionsController < ApplicationController
    before_action :require_login
    no_authorization_required! :index, :answer

    layout "global"

    current_menu_item [:index, :answer] do
      :flightplan_questions
    end

    def index
      @project = find_project
      @selected_projects = params[:projects].to_s.split(",").map(&:strip).reject(&:blank?)
      @project_choices = Flightplan::Board.project_choices(User.current)
      @questions = question_scope.to_a
      @projects = Project.visible(User.current).order(:name)
      @authors = User.where(id: question_scope.unscope(:order).distinct.pluck(:author_id)).order(:login)
    end

    def answer
      @project = find_project
      question = visible_question(params[:id])
      Flightplan::Questions::Answer.call(
        user: User.current,
        question:,
        option: params[:option],
        text: params[:text]
      )
      nxt = question_scope.open.oldest_first.first
      redirect_to inbox_path(anchor: (nxt ? "q-#{nxt.id}" : nil)), notice: t("flightplan.questions.answered")
    rescue Flightplan::Error => error
      redirect_to inbox_path(anchor: "q-#{params[:id]}"), alert: error.message
    end

    private

    def find_project
      key = params[:project_id].presence || params[:project].presence
      return if key.blank?

      project = Project.find_by(identifier: key.to_s) || Project.find_by(id: key)
      raise ActiveRecord::RecordNotFound unless project
      raise ActiveRecord::RecordNotFound unless project.visible?(User.current) || User.current.admin?

      project
    end

    def question_scope
      scope = Flightplan::Question
        .includes(:answered_by, author: :groups, work_package: %i[project status])
        .joins(:work_package)
        .merge(WorkPackage.visible(User.current))
        .oldest_first
      scope = scope.open unless params[:all] == "1"
      if @project
        scope = scope.where(work_packages: { project_id: @project.id })
      elsif params[:projects].present?
        identifiers = params[:projects].to_s.split(",").map(&:strip).reject(&:blank?)
        ids = Project.visible(User.current).where(identifier: identifiers).select(:id)
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

    def inbox_path(anchor: nil)
      options = {
        author: params[:author].presence,
        all: params[:all].presence,
        projects: params[:projects].presence,
        anchor:
      }.compact
      if @project
        project_flightplan_questions_path(@project, options)
      else
        flightplan_questions_path(options)
      end
    end
  end
end
