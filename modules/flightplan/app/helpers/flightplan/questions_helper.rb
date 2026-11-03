# frozen_string_literal: true

module Flightplan
  module QuestionsHelper
    def flightplan_agent_group(user)
      return if user.nil?

      names = user.groups.map(&:lastname)
      return "Coding" if names.include?("Agenten Coding")
      return "ADA" if names.include?("Agenten ADA")
      return "Agent" if names.include?("Agenten")

      nil
    end

    def flightplan_card_context(question)
      work_package = question.work_package
      notes = recent_notes(work_package)
      blob = [work_package.description, custom_text(work_package, "Pausenstand"), *notes.map(&:notes)].join("\n")
      {
        description: strip_tags(work_package.description.to_s).squish.truncate(280),
        pause: custom_text(work_package, "Pausenstand").to_s.squish.truncate(500),
        comments: notes.map { |journal| { author: journal.user&.login, text: journal.notes.to_s.squish.truncate(240) } },
        branch: blob[/(?:branch|Branch):\s*(\S+)/, 1],
        pull_request: blob[/https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/\d+/],
        labels: custom_list(work_package, "Labels")
      }
    end

    def recent_notes(work_package)
      scope = work_package.journals.where.not(notes: [nil, ""])
      scope = scope.where(internal: false) if Journal.column_names.include?("internal")
      scope.order(id: :desc).limit(3).reverse
    end

    def custom_text(work_package, name)
      field = WorkPackageCustomField.find_by(name:)
      return if field.nil?

      work_package.custom_values.where(custom_field_id: field.id).pick(:value)
    end

    def custom_list(work_package, name)
      field = WorkPackageCustomField.find_by(name:)
      return [] if field.nil?

      ids = work_package.custom_values.where(custom_field_id: field.id).pluck(:value)
      field.custom_options.where(id: ids).order(:position).pluck(:value)
    end
  end
end
