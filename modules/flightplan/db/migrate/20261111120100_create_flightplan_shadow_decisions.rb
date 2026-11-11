# frozen_string_literal: true

# OP#1843: Schatten-Messung. Eine Zeile entsteht nur, wenn ein Mensch eine Frage mit Empfehlung beantwortet hat. Die Tabelle
# wird nirgends gelesen, um etwas zu entscheiden; sie dient allein der Auswertung (Flightplan::ShadowRule, ::Shadow).
class CreateFlightplanShadowDecisions < ActiveRecord::Migration[8.0]
  def up
    create_table :flightplan_shadow_decisions do |t|
      t.string :source, null: false
      t.references :work_package, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.references :question, foreign_key: { to_table: :flightplan_questions, on_delete: :nullify }, index: true
      t.string :request_id
      t.string :kind
      t.boolean :reversible
      t.text :recommended
      t.text :chosen, null: false
      t.boolean :matched, null: false, default: false
      t.boolean :would_auto, null: false, default: false
      t.text :rule, null: false
      t.timestamps
    end

    add_index :flightplan_shadow_decisions, %i[source request_id work_package_id],
              unique: true, where: "request_id IS NOT NULL", name: "index_flightplan_shadow_one_per_request"
  end

  def down
    drop_table :flightplan_shadow_decisions
  end
end
