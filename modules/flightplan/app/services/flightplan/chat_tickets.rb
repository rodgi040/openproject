# frozen_string_literal: true

module Flightplan
  # OP#1711: Laufende Tickets für die Ticketleiste des Startseiten-Chats. Nur Id, Titel und Status; die Titel sind
  # untrusted und werden in der View nur escaped bzw. per textContent ausgegeben.
  class ChatTickets
    REVIEW = "Review"
    SHORT_KEYS = {
      Dashboard::STATUS_PROGRESS => :progress,
      Dashboard::STATUS_WAITING => :waiting,
      REVIEW => :review
    }.freeze
    LIMIT = 100
    SUBJECT_LENGTH = 70

    class << self
      # { items: [...], total: Gesamtzahl ohne Limit }. Reihenfolge: In Arbeit, Wartet auf Mensch, Review, darin updated_at.
      def load(user)
        ids = Status.where(name: SHORT_KEYS.keys).pluck(:name, :id).to_h.invert
        return { items: [], total: 0 } if ids.empty?

        scope = WorkPackage.visible(user).where(status_id: ids.keys)
        { items: items_from(scope, ids), total: scope.count }
      end

      def items(user)
        load(user)[:items]
      end

      private

      def items_from(scope, ids)
        rank = SHORT_KEYS.keys.each_with_index.filter_map { |name, index| "WHEN #{ids.key(name).to_i} THEN #{index}" if ids.value?(name) }
        order = Arel.sql("CASE work_packages.status_id #{rank.join(' ')} ELSE 9 END")
        scope.order(order, updated_at: :desc, id: :desc).limit(LIMIT).pluck(:id, :subject, :status_id).map do |id, subject, status_id|
          status = ids.fetch(status_id)
          { id:, subject: subject.to_s.truncate(SUBJECT_LENGTH), status:, key: SHORT_KEYS.fetch(status) }
        end
      end
    end
  end
end
