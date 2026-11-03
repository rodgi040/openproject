# frozen_string_literal: true

module Flightplan
  class Move
    def self.call(user:, work_package:, column:, lock_version:)
      spec = Board::COLUMNS.find { |entry| entry[:key] == column.to_s }
      raise Error, "Unbekannte Spalte" unless spec

      status = Status.find_by(name: spec[:status])
      raise Error, "Status #{spec[:status]} fehlt" unless status

      work_package.lock_version = parse_lock(lock_version)
      result = nil
      Journal::NotificationConfiguration.with(false) do
        result = WorkPackages::UpdateService
          .new(user:, model: work_package)
          .call(status:)
      end
      raise Error, result.errors.full_messages.join("; ") unless result.success?

      result.result
    end

    def self.parse_lock(value)
      Integer(value)
    rescue ArgumentError
      raise Error, "lockVersion fehlt"
    end
  end
end
