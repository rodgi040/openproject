# frozen_string_literal: true

module Flightplan
  # OP#1672: Suche und Filter eines Dashboard-Widgets. Die Optionen entstehen aus den Einträgen, die das Widget rendert;
  # gefiltert wird im Browser (flightplan.js, fpWidgetFilters). Ein Eintrag ist ein Hash mit :bereich, :path
  # (Projekt-Identifier, eigener zuerst, dann die Vorfahren), :statuses und :labels.
  class WidgetFilters
    # OP#1722: Übersicht, Statusleiste (Laufende Agents + Betrieb als kleine Kacheln), Board, Aufmerksamkeit. „Rückfragen“
    # steht in der Admin-Ansicht nicht mehr eigen, die Fragen stehen in „Aufmerksamkeit“ (OP#1708).
    ORDER = %w[overview status board attention].freeze
    WIDE = %w[overview attention questions board].freeze
    # Die Widgets in der Statusleiste (partial widgets/_status).
    STATUS_ORDER = %w[running betrieb].freeze
    # Für Nicht-Admins (kein Dashboard, OP#1673/OP#1674).
    MEMBER_ORDER = %w[questions board].freeze

    attr_reader :entries

    def initialize(entries, tree: [], status_order: [], scope: true)
      @entries = entries
      @tree = tree || []
      @status_order = status_order || []
      @scope = scope
    end

    # Gruppen nach Label-Familie (OP#1674, Flightplan::LabelFamilies), ohne Status-, Warte- und Art-Familie. Die Ansicht
    # rendert je Gruppe ein Fieldset mit Überschrift, das Skript verknüpft Gruppen mit UND und Labels einer Gruppe mit ODER.
    def self.label_groups(names)
      LabelFamilies.groups(names)
    end

    # agents: Filterwerte für eine Auswahl mit data-fp-filter-attr="agents"; open: false für geschlossene Einträge (zählen
    # nicht für die angebotenen Labels).
    def self.item_data(bereich: nil, path: [], statuses: [], labels: [], agents: nil, open: true)
      { fp_item: "", fp_area: bereich, fp_projects: Array(path).to_json, fp_statuses: Array(statuses).to_json,
        fp_labels: Array(labels).to_json, fp_agents: agents&.to_json, fp_open: ("0" unless open) }.compact
    end

    def count
      @entries.size
    end

    # [{ title:, options: [{ value:, label:, depth: }] }]: erst die Bereiche, dann je Bereich seine Projekte als Baum.
    def scopes
      return [] unless @scope

      bereiche = Flightplan::Dashboard::BEREICHE.values + [Flightplan::Dashboard::NO_BEREICH]
      used = @entries.flat_map { |entry| Array(entry[:path]) }.to_set
      present = @entries.filter_map { |entry| entry[:bereich] }.to_set
      groups = []
      areas = bereiche.select { |label| present.include?(label) }
      if areas.any?
        groups << { title: I18n.t("flightplan.widgets.bereiche"),
                    options: areas.map { |label| { value: "bereich:#{label}", label:, depth: 0 } } }
      end
      bereiche.each do |label|
        projects = @tree.select { |project| project[:bereich] == label && used.include?(project[:identifier]) }
        next if projects.empty?

        groups << { title: label, options: projects.map do |project|
          { value: "project:#{project[:identifier]}", label: project[:name], depth: relative_depth(project, label) }
        end }
      end
      groups
    end

    def statuses
      found = @entries.flat_map { |entry| Array(entry[:statuses]) }.uniq
      known = @status_order & found
      known + (found - known).sort
    end

    def label_groups
      self.class.label_groups(@entries.flat_map { |entry| Array(entry[:labels]) })
    end

    private

    def relative_depth(project, label)
      @bereich_of ||= @tree.to_h { |entry| [entry[:identifier], entry[:bereich]] }
      Array(project[:path]).drop(1).count { |identifier| @bereich_of[identifier] == label }
    end
  end
end
