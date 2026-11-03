# frozen_string_literal: true

module Flightplan
  module StatusChange
    module_function

    def dispatcher
      user = User.find_by(login: "dispatcher", type: "User")
      raise Error, "Nutzer dispatcher fehlt" unless user

      user
    end

    def waiting_status
      status = Status.find_by(name: Question::WAITING_STATUS)
      raise Error, "Status #{Question::WAITING_STATUS} fehlt" unless status

      status
    end

    def apply!(work_package, status)
      return work_package if work_package.status_id == status.id

      result = nil
      Journal::NotificationConfiguration.with(false) do
        result = WorkPackages::UpdateService
          .new(user: dispatcher, model: work_package)
          .call(status:)
      end
      raise Error, result.errors.full_messages.join("; ") unless result.success?

      result.result
    end
  end
end
