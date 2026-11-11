# frozen_string_literal: true

module Flightplan
  # OP#1839: Annahme eines Agenten zu einem Ticket. Höchstens eine offene je Ticket (Assumptions::Create).
  class Assumption < ApplicationRecord
    self.table_name = "flightplan_assumptions"

    STATUSES = %w[open confirmed rejected].freeze
    TEXT_LIMIT = 2000

    belongs_to :work_package
    belongs_to :author, class_name: "User"
    belongs_to :decided_by, class_name: "User", optional: true

    validates :text, presence: true, length: { maximum: TEXT_LIMIT }
    validates :status, inclusion: { in: STATUSES }

    scope :open, -> { where(status: "open") }
    scope :newest_first, -> { order(created_at: :desc, id: :desc) }
    scope :oldest_first, -> { order(:created_at, :id) }

    def open?
      status == "open"
    end
  end
end
