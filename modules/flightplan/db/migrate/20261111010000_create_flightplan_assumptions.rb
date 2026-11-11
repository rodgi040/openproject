# frozen_string_literal: true

# OP#1839: Annahmen, die ein Agent am Ticket festhält und der Mensch bestätigt oder verwirft.
class CreateFlightplanAssumptions < ActiveRecord::Migration[8.0]
  def up
    create_table :flightplan_assumptions do |t|
      t.references :work_package, null: false, foreign_key: true, index: true
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.text :text, null: false
      t.string :status, null: false, default: "open"
      t.references :decided_by, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.text :note
      t.timestamps
    end

    add_index :flightplan_assumptions, %i[status created_at]
  end

  def down
    drop_table :flightplan_assumptions
  end
end
