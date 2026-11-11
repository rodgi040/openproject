# frozen_string_literal: true

# OP#1839: Annahmen, die ein Agent am Ticket festhält und der Mensch bestätigt oder verwirft.
class CreateFlightplanAssumptions < ActiveRecord::Migration[8.0]
  def up
    create_table :flightplan_assumptions do |t|
      t.references :work_package, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.text :text, null: false
      t.string :status, null: false, default: "open"
      t.references :decided_by, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.text :note
      t.timestamps
    end

    add_index :flightplan_assumptions, %i[status created_at]
    # Zweite Absicherung zur Grenze "höchstens eine offene Annahme je Ticket" (Assumptions::Create prüft zuerst).
    add_index :flightplan_assumptions, :work_package_id, unique: true, where: "status = 'open'",
                                                        name: "index_flightplan_assumptions_one_open_per_wp"
  end

  def down
    drop_table :flightplan_assumptions
  end
end
