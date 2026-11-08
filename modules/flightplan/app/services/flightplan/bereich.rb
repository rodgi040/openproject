# frozen_string_literal: true

module Flightplan
  # OP#1674 (OP#1670 D4): Der Bereich eines Projekts ist die Wurzel seiner Projekt-Hierarchie. Board und Dashboard rechnen
  # beide hiermit; „Ohne Bereich“ gilt nur für Wurzeln außerhalb der drei Bereiche. Das Projektattribut „Bereich“ zählt
  # nicht mehr. Die Wurzel wird über alle Projekte bestimmt, auch über für den Nutzer unsichtbare Vorfahren.
  module Bereich
    OHNE_KEY = "ohne"

    module_function

    # project_id => Bereich-Name (Dashboard::BEREICHE-Wert oder Dashboard::NO_BEREICH), für alle Projekte.
    def by_project_id
      rows = Project.pluck(:id, :parent_id, :identifier)
      parents = rows.to_h { |id, parent_id, _| [id, parent_id] }
      identifiers = rows.to_h { |id, _, identifier| [id, identifier] }
      rows.to_h do |id, _, _|
        root = id
        steps = 0
        while parents[root] && parents.key?(parents[root]) && steps < 64
          root = parents[root]
          steps += 1
        end
        [id, Dashboard::BEREICHE[identifiers[root]] || Dashboard::NO_BEREICH]
      end
    end

    def labels
      Dashboard::BEREICHE.values + [Dashboard::NO_BEREICH]
    end

    # Parameter-Schlüssel eines Bereichs: Identifier der Wurzel, "ohne" für „Ohne Bereich“.
    def key_for(label)
      Dashboard::BEREICHE.key(label) || OHNE_KEY
    end

    def label_for(key)
      return Dashboard::NO_BEREICH if key.to_s == OHNE_KEY

      Dashboard::BEREICHE[key.to_s]
    end
  end
end
