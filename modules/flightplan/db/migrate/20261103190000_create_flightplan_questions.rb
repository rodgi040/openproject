# frozen_string_literal: true

class CreateFlightplanQuestions < ActiveRecord::Migration[8.0]
  def change
    create_table :flightplan_questions do |t|
      t.references :work_package, null: false, foreign_key: true, index: true
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.text :question, null: false
      t.text :context
      t.jsonb :options, null: false, default: []
      t.string :status, null: false, default: "open"
      t.text :answer
      t.string :chosen_option
      t.references :answered_by, foreign_key: { to_table: :users }
      t.datetime :answered_at
      t.references :previous_status, foreign_key: { to_table: :statuses }
      t.timestamps
    end

    add_index :flightplan_questions, %i[status created_at]
  end
end
