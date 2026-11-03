# frozen_string_literal: true

Rails.application.routes.draw do
  get "flightplan", to: "flightplan/home#show", as: :flightplan
end
