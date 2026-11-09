# frozen_string_literal: true

module Flightplan
  # OP#1674: Familie je Label aus config/label_families.yml. Einzige Stelle, die die Datei liest; erzeugt sie später die
  # Factory aus openproject/config/labels.yml, ändert sich hier nichts.
  module LabelFamilies
    PATH = "config/label_families.yml"

    module_function

    def data
      @data ||= load_data
    end

    def reload!
      @data = nil
      @family_cache = nil
    end

    def load_data
      raw = YAML.safe_load_file(OpenProject::Flightplan::Engine.root.join(PATH)) || {}
      families = Array(raw["families"]).map do |row|
        # OP#1706: Eine Familie ohne title bekommt ihren Schlüssel als Namen, nie eine leere Überschrift.
        { key: row["key"].to_s, title: row["title"].to_s.strip.presence || row["key"].to_s.humanize, filter: row.fetch("filter", true) != false,
          card: row.fetch("card", true) != false, names: Array(row["names"]).map(&:to_s).to_set,
          prefixes: Array(row["prefixes"]).map(&:to_s) }
      end
      agent = raw["agent_labels"] || {}
      { families:, default: raw["default"].to_s, types: (raw["types"] || {}).to_h { |name, type| [name.to_s, type.to_s] },
        agent_names: Array(agent["names"]).map(&:to_s).to_set, agent_suffixes: Array(agent["suffixes"]).map(&:to_s) }
    end

    def families
      data[:families]
    end

    def family_for(name)
      @family_cache ||= {}
      @family_cache[name.to_s] ||= begin
        text = name.to_s
        found = families.find { |family| family[:names].include?(text) } ||
                families.find { |family| family[:prefixes].any? { |prefix| text.start_with?(prefix) } } ||
                families.find { |family| family[:key] == data[:default] }
        found.slice(:key, :title, :filter, :card)
      end
    end

    # [{ key:, title:, names: }] in der Reihenfolge der Familien, nur Familien mit Filter, Namen sortiert.
    def groups(names)
      grouped = names.compact_blank.uniq.group_by { |name| family_for(name)[:key] }
      families.filter_map do |family|
        next unless family[:filter] && grouped[family[:key]]

        { key: family[:key], title: family[:title], names: grouped[family[:key]].sort_by { |name| [name.downcase, name] } }
      end
    end

    def filter?(name)
      family_for(name)[:filter]
    end

    # Labels, die als Chip auf eine Karte gehören: ohne Familien mit card: false und ohne Label, das den Typ wiederholt.
    def card_labels(names, type_name)
      names.reject do |name|
        !family_for(name)[:card] || (type_name.present? && data[:types][name.to_s] == type_name.to_s)
      end
    end

    def agent_label?(name)
      text = name.to_s
      data[:agent_names].include?(text) || data[:agent_suffixes].any? { |suffix| text.end_with?(suffix) }
    end

    # „Weg fehlt“: Startfreigabe ohne Ausführungsweg und ohne Agent-Label.
    def path_missing?(status:, path:, labels:)
      status == Dashboard::STATUS_START && path.blank? && labels.none? { |name| agent_label?(name) }
    end
  end
end
