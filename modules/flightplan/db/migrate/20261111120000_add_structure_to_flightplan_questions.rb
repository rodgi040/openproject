# frozen_string_literal: true

# OP#1842: Rückfrage mit Struktur. Alle Spalten sind nullbar: ältere Rückfragen und Aufrufe ohne diese Felder bleiben gültig.
class AddStructureToFlightplanQuestions < ActiveRecord::Migration[8.0]
  def up
    add_column :flightplan_questions, :kind, :string
    add_column :flightplan_questions, :recommended_option, :string
    add_column :flightplan_questions, :reversible, :boolean
    add_column :flightplan_questions, :consequence, :text
  end

  def down
    remove_column :flightplan_questions, :consequence
    remove_column :flightplan_questions, :reversible
    remove_column :flightplan_questions, :recommended_option
    remove_column :flightplan_questions, :kind
  end
end
