# frozen_string_literal: true

module Flightplan
  module Menu
    module_function

    def agent_directory
      rows = []
      {
        "Agenten Coding" => "Coding",
        "Agenten ADA" => "ADA"
      }.each do |group_name, label|
        group = Group.find_by(lastname: group_name)
        next unless group

        group.users.each do |user|
          rows << { id: user.id, group: label, name: user.name }
        end
      end
      rows
    rescue StandardError
      []
    end

    def open_question_links(user)
      Question.open
        .includes(:work_package)
        .oldest_first
        .limit(200)
        .select { |question| question.work_package.visible?(user) || user.admin? }
        .map do |question|
          {
            work_package_id: question.work_package_id,
            href: "/#q-#{question.id}"
          }
        end
    rescue StandardError
      []
    end
  end
end
