# frozen_string_literal: true

module Flightplan
  # One visible-scope read, then bulk lookups for the cards actually shown.
  class Board
    PAGE = 200
    DONE_WINDOW = 14
    COLUMNS = [
      { key: "triage", status: "Neu" },
      { key: "question", status: "Wartet auf Mensch" },
      { key: "for_you", status: "Geplant" },
      { key: "agent_ready", status: "Startfreigabe" },
      { key: "in_progress", status: "In Arbeit" },
      { key: "review", status: "Review" },
      { key: "done", status: "Fertig" },
      { key: "rejected", status: "Abgelehnt" }
    ].freeze
    STATUS_NAMES = COLUMNS.map { |column| column[:status] }.freeze
    GROUP_NAMES = {
      "Agenten Coding" => "Coding",
      "Agenten ADA" => "ADA"
    }.freeze
    PARENT_TYPES = %w[Dach Phase].freeze

    Column = Struct.new(:key, :status, :count, :shown, :cards, keyword_init: true)
    Card = Struct.new(
      :id, :subject, :project_identifier, :project_name, :updated_at, :lock_version,
      :labels, :assignee, :involved, :pause, :execution_path, :children,
      :question_count, :question_id, :show_children,
      keyword_init: true
    )
    Person = Struct.new(:id, :name, :initials, :group, keyword_init: true)

    def self.load(user:, params:)
      new(user, params).load
    end

    def self.project_choices(user)
      counts = WorkPackage.visible(user).joins(:status).where(statuses: { is_closed: false }).group(:project_id).count
      Project.visible(user).order(:name).map do |project|
        { identifier: project.identifier, name: project.name, open_count: counts[project.id].to_i }
      end
    end

    def self.colors
      @colors ||= load_colors
    end

    def self.load_colors
      path = OpenProject::Flightplan::Engine.root.join("config/label_colors.yml")
      return {} unless path.file?

      data = YAML.safe_load_file(path) || {}
      Array(data["labels"]).each_with_object({}) do |row, map|
        next unless row.is_a?(Hash) && row["name"].present?

        map[row["name"].to_s] = row["color"].to_s
      end
    end

    def initialize(user, params)
      @user = user
      @raw = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @raw = @raw.deep_stringify_keys
    end

    def load
      load_agents
      load_fields
      place_rows
      self
    end

    attr_reader :columns

    def projects
      @projects ||= begin
        rows = self.class.project_choices(@user)
        if (under = bereich_identifiers)
          rows = rows.select { |choice| under.include?(choice[:identifier]) }
        end
        rows.map { |choice| choice.merge(selected: selected_projects.include?(choice[:identifier])) }
      end
    end

    def bereiche
      @bereiche ||= begin
        counts = self.class.project_choices(@user).index_by { |row| row[:identifier] }
        grouped = {}
        Project.visible(@user).order(:lft).each do |project|
          roof = roof_for(project)
          bucket = grouped[roof.identifier] ||= {
            identifier: roof.identifier,
            name: roof.name,
            open_count: 0,
            selected: roof.identifier == selected_bereich
          }
          bucket[:open_count] += counts.dig(project.identifier, :open_count).to_i
        end
        grouped.values.sort_by { |row| row[:name].downcase }
      end
    end

    def selected_bereich
      @selected_bereich ||= @raw["bereich"].to_s.strip.presence
    end

    def all_open_count
      projects.sum { |choice| choice[:open_count] }
    end

    def selected_projects
      @selected_projects ||= split("projects")
    end

    def selected_labels
      @selected_labels ||= split("labels")
    end

    def selected_agents
      @selected_agents ||= split("agents")
    end

    def query_text
      @raw["q"].to_s.strip
    end

    def show_rejected?
      @raw["rejected"] == "1"
    end

    def done_all?
      @raw["done"] == "all"
    end

    def label_options
      return [] unless labels_field

      labels_field.custom_options.order(:value).pluck(:value).map do |name|
        color = color_hex(self.class.colors[name])
        { name:, color:, ink: ink_for(color), selected: selected_labels.include?(name) }
      end
    end

    def agent_options
      groups = [
        { key: "coding", label: "Coding" },
        { key: "ada", label: "ADA" }
      ]
      people = @agents.map { |agent| { key: agent[:login], label: agent[:name] } }
      (groups + people).map { |option| option.merge(selected: selected_agents.include?(option[:key])) }
    end

    def wiki_projects
      chosen = selected_projects
      rows = chosen.empty? ? projects : projects.select { |choice| chosen.include?(choice[:identifier]) }
      found = Project.visible(@user).where(identifier: rows.map { |row| row[:identifier] }).includes(:wiki).index_by(&:identifier)
      helpers = Rails.application.routes.url_helpers
      rows.filter_map do |choice|
        project = found[choice[:identifier]]
        next unless project

        slug = project.wiki&.start_page.presence || "wiki"
        { name: choice[:name], href: helpers.project_wiki_path(project, slug) }
      end
    end

    def params_for(overrides = {})
      next_query = query.deep_dup
      overrides.each do |key, value|
        if value.nil? || value == ""
          next_query.delete(key.to_s)
        else
          next_query[key.to_s] = value
        end
      end
      if next_query["limits"].is_a?(Hash)
        kept = next_query["limits"].each_with_object({}) do |(key, value), memo|
          memo[key.to_s] = value.to_i if value.to_i > PAGE && COLUMNS.any? { |column| column[:key] == key.to_s }
        end
        if kept.empty?
          next_query.delete("limits")
        else
          next_query["limits"] = kept
        end
      end
      next_query.delete_if { |_, value| value.blank? }
    end

    def limit_for(key)
      limits = @raw["limits"]
      raw = limits.is_a?(Hash) ? limits[key].to_i : 0
      raw = PAGE if raw <= 0
      [raw, 500].min
    end

    def limits
      @limits ||= COLUMNS.to_h { |column| [column[:key], limit_for(column[:key])] }
    end

    private

    def query
      @query ||= {
        "projects" => selected_projects.join(",").presence,
        "bereich" => selected_bereich,
        "q" => query_text.presence,
        "labels" => selected_labels.join(",").presence,
        "agents" => selected_agents.join(",").presence,
        "rejected" => ("1" if show_rejected?),
        "done" => ("all" if done_all?),
        "limits" => limits
      }.compact
    end

    def split(key)
      @raw[key].to_s.split(",").map(&:strip).reject(&:blank?)
    end

    def load_agents
      groups = Group.where(lastname: GROUP_NAMES.keys).pluck(:id, :lastname).to_h
      memberships = GroupUser.where(group_id: groups.keys).pluck(:group_id, :user_id)
      users = User.where(id: memberships.map(&:last).uniq).pluck(:id, :login, :firstname, :lastname)
      by_id = users.to_h { |id, login, first, last| [id, { login:, name: [first, last].compact_blank.join(" ").presence || login }] }
      @agents = memberships.filter_map do |group_id, user_id|
        user = by_id[user_id]
        next unless user

        user.merge(id: user_id, group: GROUP_NAMES[groups[group_id]])
      end
      @agent_ids = @agents.map { |agent| agent[:id] }.to_set
    end

    def load_fields
      names = WorkPackageCustomField.where(name: ["Labels", "Pausenstand", "Ausführungsweg", "Beteiligte Agenten"])
      @fields = names.index_by(&:name)
    end

    def labels_field
      @fields["Labels"]
    end

    def place_rows
      buckets = Hash.new { |hash, key| hash[key] = [] }
      filtered.pluck("work_packages.id", "statuses.name", "work_packages.assigned_to_id", "work_packages.updated_at")
        .each do |id, status_name, assignee_id, updated_at|
          key = column_key(status_name, assignee_id)
          buckets[key] << [updated_at, id] if key
        end
      buckets.each_value { |rows| rows.sort_by! { |updated_at, id| [-(updated_at&.to_f || 0), -id] } }
      shown = {}
      @columns = COLUMNS.filter_map do |column|
        next if column[:key] == "rejected" && !show_rejected?

        rows = buckets[column[:key]]
        limit = limits[column[:key]]
        ids = rows.first(limit).map(&:last)
        shown[column[:key]] = ids
        Column.new(key: column[:key], status: column[:status], count: rows.size, shown: ids.size, cards: [])
      end
      cards = build_cards(shown.values.flatten)
      @columns.each do |column|
        column.cards = shown[column.key].filter_map { |id| cards[id] }
      end
    end

    def column_key(status_name, assignee_id)
      case status_name
      when "Neu" then "triage"
      when "Wartet auf Mensch" then "question"
      when "Startfreigabe" then "agent_ready"
      when "In Arbeit" then "in_progress"
      when "Review" then "review"
      when "Fertig" then "done"
      when "Abgelehnt" then "rejected"
      when "Geplant" then @agent_ids.include?(assignee_id) ? "agent_ready" : "for_you"
      end
    end

    def filtered
      scope = WorkPackage.visible(@user).joins(:status)
      scope = apply_projects(scope)
      scope = apply_search(scope)
      scope = apply_labels(scope)
      scope = apply_agents(scope)
      names = show_rejected? ? STATUS_NAMES : STATUS_NAMES - ["Abgelehnt"]
      scope = scope.where(statuses: { name: names })
      return scope if done_all?

      scope.joins(closed_join).where(
        "statuses.name <> 'Fertig' OR COALESCE(fp_closed.closed_at, work_packages.updated_at) >= ?",
        DONE_WINDOW.days.ago
      )
    end

    def apply_projects(scope)
      identifiers = scoped_identifiers
      return scope if identifiers.nil?

      ids = Project.visible(@user).where(identifier: identifiers).select(:id)
      scope.where(project_id: ids)
    end

    def scoped_identifiers
      under = bereich_identifiers
      chosen = selected_projects
      if under
        list = chosen.empty? ? under : (chosen & under)
        return list
      end
      return nil if chosen.empty?

      chosen
    end

    def bereich_identifiers
      return @bereich_identifiers if defined?(@bereich_identifiers)

      @bereich_identifiers = if selected_bereich.blank?
        nil
      else
        root = Project.visible(@user).find_by(identifier: selected_bereich)
        root && Project.visible(@user).where(id: root.self_and_descendants.select(:id)).pluck(:identifier)
      end
    end

    def roof_for(project)
      project.ancestors_from_root.find { |ancestor| ancestor.visible?(@user) } || project
    end

    def apply_search(scope)
      term = query_text
      return scope if term.blank?

      like = "%#{ActiveRecord::Base.sanitize_sql_like(term.delete_prefix('#'))}%"
      parts = ["work_packages.subject ILIKE :like"]
      binds = { like: }
      bare = term.delete_prefix("#")
      if bare.match?(/\A\d+\z/)
        parts << "work_packages.id = :wid"
        binds[:wid] = bare.to_i
      end
      if labels_field
        parts << label_exists_sql("custom_options.value ILIKE :like")
        binds[:label_field_id] = labels_field.id
      end
      scope.where(parts.join(" OR "), binds)
    end

    def apply_labels(scope)
      return scope if selected_labels.empty?
      return scope.none unless labels_field

      scope.where(
        label_exists_sql("custom_options.value IN (:label_names)"),
        label_field_id: labels_field.id,
        label_names: selected_labels
      )
    end

    def label_exists_sql(predicate)
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM custom_values
          INNER JOIN custom_options
            ON custom_options.custom_field_id = custom_values.custom_field_id
           AND custom_options.id::text = custom_values.value
          WHERE custom_values.customized_type = 'WorkPackage'
            AND custom_values.customized_id = work_packages.id
            AND custom_values.custom_field_id = :label_field_id
            AND #{predicate}
        )
      SQL
    end

    def apply_agents(scope)
      return scope if selected_agents.empty?

      ids = selected_agent_ids
      return scope.none if ids.empty?

      parts = ["work_packages.assigned_to_id IN (:agent_ids)"]
      binds = { agent_ids: ids }
      if (field = @fields["Beteiligte Agenten"])
        parts << <<~SQL.squish
          EXISTS (
            SELECT 1 FROM custom_values
            WHERE custom_values.customized_type = 'WorkPackage'
              AND custom_values.customized_id = work_packages.id
              AND custom_values.custom_field_id = :involved_field_id
              AND custom_values.value IN (:agent_id_strings)
          )
        SQL
        binds[:involved_field_id] = field.id
        binds[:agent_id_strings] = ids.map(&:to_s)
      end
      scope.where(parts.join(" OR "), binds)
    end

    def selected_agent_ids
      selected_agents.flat_map do |token|
        case token
        when "coding" then @agents.select { |agent| agent[:group] == "Coding" }.map { |agent| agent[:id] }
        when "ada" then @agents.select { |agent| agent[:group] == "ADA" }.map { |agent| agent[:id] }
        else
          found = @agents.find { |agent| agent[:login] == token }
          found ? [found[:id]] : []
        end
      end.uniq
    end

    def closed_join
      fertig_id = Status.where(name: "Fertig").pick(:id)
      sql = if fertig_id.nil?
        "SELECT NULL::bigint AS work_package_id, NULL::timestamp AS closed_at WHERE FALSE"
      else
        closed_at_sql(fertig_id)
      end
      "LEFT JOIN (#{sql}) fp_closed ON fp_closed.work_package_id = work_packages.id"
    end

    def closed_at_sql(fertig_id)
      <<~SQL.squish
        SELECT journable_id AS work_package_id, MAX(created_at) AS closed_at
        FROM (
          SELECT journals.journable_id, journals.created_at, work_package_journals.status_id,
                 LAG(work_package_journals.status_id) OVER (
                   PARTITION BY journals.journable_id
                   ORDER BY journals.version ASC, journals.id ASC
                 ) AS prev_status
          FROM journals
          INNER JOIN work_package_journals
            ON work_package_journals.id = journals.data_id
           AND journals.data_type = 'Journal::WorkPackageJournal'
          WHERE journals.journable_type = 'WorkPackage'
            AND journals.journable_id IN (
              SELECT id FROM work_packages WHERE status_id = #{fertig_id.to_i}
            )
        ) fp_transitions
        WHERE status_id = #{fertig_id.to_i}
          AND prev_status IS DISTINCT FROM status_id
        GROUP BY journable_id
      SQL
    end

    def build_cards(ids)
      return {} if ids.empty?

      rows = WorkPackage.where(id: ids).pluck(
        :id, :subject, :project_id, :updated_at, :assigned_to_id, :type_id, :lock_version
      )
      projects = Project.where(id: rows.map { |row| row[2] }.uniq).pluck(:id, :identifier, :name).to_h do |id, identifier, name|
        [id, [identifier, name]]
      end
      types = Type.where(id: rows.map { |row| row[5] }.uniq).pluck(:id, :name).to_h
      extras = card_extras(ids, rows, types)
      rows.to_h do |id, subject, project_id, updated_at, assignee_id, type_id, lock_version|
        identifier, name = projects[project_id] || ["", ""]
        type_name = types[type_id]
        [
          id,
          Card.new(
            id:,
            subject:,
            project_identifier: identifier,
            project_name: name,
            updated_at:,
            lock_version:,
            labels: extras[:labels][id] || [],
            assignee: extras[:people][assignee_id],
            involved: (extras[:involved][id] || []).reject { |person| person.id == assignee_id },
            pause: extras[:pause].include?(id),
            execution_path: extras[:paths][id],
            children: extras[:children][id].to_i,
            question_count: extras[:questions][id].to_i,
            question_id: extras[:question_ids][id],
            show_children: PARENT_TYPES.include?(type_name)
          )
        ]
      end
    end

    def card_extras(ids, rows, types)
      people = people_for(rows, ids)
      {
        labels: labels_for(ids),
        people:,
        involved: involved_for(ids, people),
        pause: pause_ids(ids),
        paths: paths_for(ids),
        children: children_for(ids, rows, types),
        questions: {},
        question_ids: {}
      }.tap do |extras|
        question_rows(ids, extras)
      end
    end

    def people_for(rows, ids)
      ids_needed = rows.filter_map { |row| row[4] }
      ids_needed |= involved_user_ids(ids)
      users = User.where(id: ids_needed.uniq).pluck(:id, :login, :firstname, :lastname)
      agents = @agents.index_by { |agent| agent[:id] }
      users.to_h do |id, login, first, last|
        name = [first, last].compact_blank.join(" ").presence || login
        agent = agents[id]
        [id, Person.new(id:, name:, initials: initials(name), group: agent && agent[:group])]
      end
    end

    def involved_user_ids(ids)
      field = @fields["Beteiligte Agenten"]
      return [] unless field

      CustomValue.where(custom_field_id: field.id, customized_type: "WorkPackage", customized_id: ids).pluck(:value)
        .filter_map { |value| Integer(value, exception: false) }
    end

    def involved_for(ids, people)
      field = @fields["Beteiligte Agenten"]
      return {} unless field

      grouped = Hash.new { |hash, key| hash[key] = [] }
      CustomValue.where(custom_field_id: field.id, customized_type: "WorkPackage", customized_id: ids)
        .pluck(:customized_id, :value).each do |work_package_id, value|
          person = people[Integer(value, exception: false)]
          grouped[work_package_id] << person if person
        end
      grouped
    end

    def labels_for(ids)
      return {} unless labels_field

      options = labels_field.custom_options.pluck(:id, :value).to_h { |id, value| [id.to_s, value] }
      grouped = Hash.new { |hash, key| hash[key] = [] }
      CustomValue.where(custom_field_id: labels_field.id, customized_type: "WorkPackage", customized_id: ids)
        .pluck(:customized_id, :value).each do |work_package_id, value|
          name = options[value.to_s]
          next if name.blank?

          color = color_hex(self.class.colors[name])
          grouped[work_package_id] << { name:, color:, ink: ink_for(color) }
        end
      grouped
    end

    def pause_ids(ids)
      field = @fields["Pausenstand"]
      return Set.new unless field

      CustomValue.where(custom_field_id: field.id, customized_type: "WorkPackage", customized_id: ids)
        .where.not(value: [nil, ""]).pluck(:customized_id).to_set
    end

    def paths_for(ids)
      field = @fields["Ausführungsweg"]
      return {} unless field

      options = field.custom_options.pluck(:id, :value).to_h { |id, value| [id.to_s, value] }
      CustomValue.where(custom_field_id: field.id, customized_type: "WorkPackage", customized_id: ids)
        .pluck(:customized_id, :value).to_h { |work_package_id, value| [work_package_id, options[value.to_s]] }
    end

    def children_for(ids, rows, types)
      parent_ids = rows.filter_map { |id, _, _, _, _, type_id, _| id if PARENT_TYPES.include?(types[type_id]) }
      return {} if parent_ids.empty?

      WorkPackage.visible(@user).where(parent_id: parent_ids).group(:parent_id).count
    end

    def question_rows(ids, extras)
      Flightplan::Question.open.where(work_package_id: ids).order(:created_at, :id).pluck(:work_package_id, :id)
        .each do |work_package_id, question_id|
          extras[:questions][work_package_id] = extras[:questions][work_package_id].to_i + 1
          extras[:question_ids][work_package_id] ||= question_id
        end
    end

    def initials(name)
      parts = name.to_s.split.reject { |part| part == "-" }
      letters = parts.first(2).filter_map { |part| part[0] }
      letters.join.upcase.presence || "?"
    end

    def color_hex(raw)
      hex = raw.to_s.delete_prefix("#").strip
      hex = hex.chars.map { |char| char * 2 }.join if hex.match?(/\A[0-9a-fA-F]{3}\z/)
      return "6e7781" unless hex.match?(/\A[0-9a-fA-F]{6}\z/)

      hex.downcase
    end

    def ink_for(hex)
      red, green, blue = hex.scan(/../).map { |part| part.to_i(16) }
      ((0.299 * red) + (0.587 * green) + (0.114 * blue)) > 150 ? "1f2328" : "ffffff"
    end
  end
end
