# frozen_string_literal: true

Rails.application.routes.draw do
  get "flightplan", to: "flightplan/home#show", as: :flightplan
  get "flightplan/questions", to: "flightplan/questions#index", as: :flightplan_questions
  post "flightplan/questions/:id/answer", to: "flightplan/questions#answer", as: :flightplan_question_answer
  get "projects/:project_id/flightplan/questions", to: "flightplan/questions#index", as: :project_flightplan_questions
  get "flightplan/assets/flightplan.js", to: "flightplan/assets#javascript", as: :flightplan_javascript
  get "flightplan/assets/flightplan.css", to: "flightplan/assets#stylesheet", as: :flightplan_stylesheet
end
