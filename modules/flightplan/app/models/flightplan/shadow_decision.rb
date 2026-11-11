# frozen_string_literal: true

module Flightplan
  # OP#1843: Eine Zeile je Frage mit Empfehlung, die ein Mensch beantwortet hat. Nur Messung: nichts liest diese Tabelle, um
  # eine Frage zu beantworten. `would_auto` ist, was die Regel SHADOW_RULE_V1 getan HÄTTE.
  class ShadowDecision < ApplicationRecord
    self.table_name = "flightplan_shadow_decisions"

    SOURCES = %w[ask chat].freeze
    FIELD_MAX = 500

    belongs_to :work_package
    belongs_to :question, optional: true

    validates :source, inclusion: { in: SOURCES }
    validates :chosen, :rule, presence: true
    validates :recommended, :chosen, length: { maximum: FIELD_MAX }
    validates :request_id, length: { maximum: 200 }
  end
end
