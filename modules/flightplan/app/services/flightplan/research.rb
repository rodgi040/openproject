# frozen_string_literal: true

module Flightplan
  # OP#2841: Recherchen sind Arbeitspakete vom Typ „Recherche“. Dieses Modul löst Typ und Felder zur Laufzeit nach
  # Namen auf, baut die query_props der Indexliste und nimmt den Typ aus Board und Dashboard heraus.
  module Research
    TYPE_NAME = "Recherche"
    SHORT_ANSWER_FIELD = "Kurzantwort"
    CONFIDENCE_FIELD = "Konfidenz"

    module_function

    def type_id
      ::Type.where(name: TYPE_NAME).pick(:id)
    end

    def visible_in?(project)
      project.present? && project.module_enabled?("work_package_tracking") &&
        project.types.exists?(name: TYPE_NAME)
    end

    # Ohne Typ Recherche bleibt der Scope unverändert.
    def excluding(scope)
      id = type_id
      id ? scope.where.not(type_id: id) : scope
    end

    # Schlüssel wie in work_packages_filter_helper.rb (f, t) und ParseQueryParamsService (c);
    # Filter {n:, o:, v:}, Feldspalten als customField<id>.
    def query_props(type_id)
      fields = [SHORT_ANSWER_FIELD, CONFIDENCE_FIELD].filter_map do |name|
        field = ::WorkPackageCustomField.find_by(name:)
        "customField#{field.id}" if field
      end
      {
        f: [
          { n: "type", o: "=", v: [type_id.to_s] },
          { n: "status", o: "*" },
          { n: "subprojectId", o: "*" }
        ],
        c: %w[id subject project] + fields + %w[updatedAt],
        t: "updated_at:desc"
      }
    end
  end
end
