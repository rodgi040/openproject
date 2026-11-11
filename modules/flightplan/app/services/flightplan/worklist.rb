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

    # OP#1835: Abschnitt „Braucht dich“ oben in der Arbeitsliste. Die Reihenfolge ist der Rang: Befehlsfreigabe, offene
    # Rückfrage, Lauf fehlgeschlagen, Eingabe nötig. Nur die Rückfragen kennt der Server (Tabelle flightplan_questions);
    # die anderen drei Arten kommen als Laufzustand je Ticket per fp:activity im Browser an (flightplan.js, fpInbox).
    INBOX_KINDS = %w[approval question error input].freeze
    # Laufzustände, die T3 je Ticket melden darf (fp:activity v2). `working` erscheint nicht im Abschnitt, nur als Pille.
    RUN_STATES = %w[working approval input error].freeze

    # Die Rückfragen des Abschnitts: genau die offenen Rückfragen, die der Nutzer sehen darf (Zeilen aus QuestionsWidget),
    # älteste zuerst, ohne Begrenzung auf SHOWN. Ein gespiegeltes Ticket im Status „Wartet auf Mensch“ ohne offene Frage
    # hat hier keine Zeile, weil es keine Rückfrage gibt, aus der eine entstünde.
    def self.inbox_questions(rows)
      Array(rows).select { |row| row[:text].present? }.sort_by { |row| [row[:since], row[:id]] }
    end

    def self.inbox_count(rows)
      inbox_questions(rows).size
    end
  end
end
