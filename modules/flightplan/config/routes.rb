# frozen_string_literal: true

Rails.application.routes.draw do
  get "flightplan", to: "flightplan/home#show", as: :flightplan
  get "flightplan/dashboard", to: "flightplan/dashboard#index", as: :flightplan_dashboard
  get "flightplan/approvals", to: "flightplan/approvals#index", as: :flightplan_approvals
  post "flightplan/approvals", to: "flightplan/approvals#create", as: :flightplan_approvals_create
  get "flightplan/board", to: "flightplan/board#index", as: :flightplan_board
  get "flightplan/work_packages/:id", to: "flightplan/workplace#show", as: :flightplan_workplace
  post "flightplan/board/move", to: "flightplan/board#move", as: :flightplan_board_move
  get "flightplan/questions", to: "flightplan/questions#index", as: :flightplan_questions
  post "flightplan/questions/:id/answer", to: "flightplan/questions#answer", as: :flightplan_question_answer
  get "projects/:project_id/flightplan/questions", to: "flightplan/questions#index", as: :project_flightplan_questions
  get "flightplan/chat/context", to: "flightplan/chat#ticket_context", as: :flightplan_chat_context
  get "flightplan/chat/events", to: "flightplan/chat#events", as: :flightplan_chat_events
  post "flightplan/chat/comments", to: "flightplan/chat#comment", as: :flightplan_chat_comment
  get "flightplan/assets/flightplan.js", to: "flightplan/assets#javascript", as: :flightplan_javascript
  get "flightplan/assets/flightplan.css", to: "flightplan/assets#stylesheet", as: :flightplan_stylesheet
end
