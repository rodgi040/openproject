# frozen_string_literal: true

module Flightplan
  class Question < ApplicationRecord
    self.table_name = "flightplan_questions"

    STATUSES = %w[open answered].freeze
    WAITING_STATUS = "Wartet auf Mensch"
    # OP#1842: Art der Rückfrage (fp-op ask --kind) und Obergrenze der Folge-Zeile.
    KINDS = %w[entscheidung freigabe zugang abnahme].freeze
    CONSEQUENCE_MAX = 500

    belongs_to :work_package
    belongs_to :author, class_name: "User"
    belongs_to :answered_by, class_name: "User", optional: true
    belongs_to :previous_status, class_name: "Status", optional: true

    # Nur die Antwort-JSON. Nicht gespeichert.
    attr_accessor :status_restored

    validates :question, presence: true
    validates :status, inclusion: { in: STATUSES }
    validate :options_are_strings
    validates :kind, inclusion: { in: KINDS }, allow_nil: true
    validates :consequence, length: { maximum: CONSEQUENCE_MAX }, allow_nil: true
    validate :recommended_is_an_option

    scope :open, -> { where(status: "open") }
    scope :answered, -> { where(status: "answered") }
    scope :oldest_first, -> { order(:created_at, :id) }

    def options
      Array(self[:options])
    end

    def open?
      status == "open"
    end

    private

    def recommended_is_an_option
      return if recommended_option.blank?
      return if options.include?(recommended_option)

      errors.add(:recommended_option, "muss eine der Optionen sein")
    end

    def options_are_strings
      return if self[:options].blank?
      return if self[:options].is_a?(Array) && self[:options].all?(String)

      errors.add(:options, "muss eine Liste von Texten sein")
    end
  end
end
