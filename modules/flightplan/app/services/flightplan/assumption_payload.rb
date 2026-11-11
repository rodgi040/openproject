# frozen_string_literal: true

module Flightplan
  module AssumptionPayload
    module_function

    def dump(assumption)
      {
        id: assumption.id,
        work_package_id: assumption.work_package_id,
        text: assumption.text,
        status: assumption.status,
        author: assumption.author.login,
        created_at: assumption.created_at&.iso8601,
        decided_by: assumption.decided_by&.login,
        decided_at: assumption.decided_at&.iso8601,
        note: assumption.note
      }
    end
  end
end
