# frozen_string_literal: true

module Flightplan
  # OP#1778 Teil 2: Reiter der Arbeitsliste. Jeder Reiter bündelt Board-Spalten (Flightplan::Board::COLUMNS) nach der
  # Frage des Nutzers; die Reihenfolge der Schlüssel ist die Reihenfolge der Gruppen.
  module Worklist
    TABS = {
      "fuer_dich" => %w[question for_you human],
      "laeuft" => %w[in_progress review agent_ready done],
      "triage" => %w[triage],
      "projekte" => []
    }.freeze
    COLLAPSED = %w[done].freeze
    SHOWN = 4
    VIEWS = %w[board worklist].freeze
  end
end
