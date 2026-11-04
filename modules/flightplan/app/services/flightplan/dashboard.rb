# frozen_string_literal: true

module Flightplan
  # ADA Dashboard (S4): Aufmerksamkeitstabelle und Kacheln. Nur lesend (H7).
  # Die Ticketdaten kommen mit je einer Abfrage aus OpenProject (pluck, GROUP BY), nicht über APIv3.
  # Das Ergebnis liegt 30 s im Cache; der Bereichsfilter wirkt erst danach im Speicher.
  class Dashboard
    CACHE_SECONDS = 30
    STALE_DAYS = 7
    STATUS_WAITING = "Wartet auf Mensch"
    STATUS_START = "Startfreigabe"
    STATUS_PROGRESS = "In Arbeit"
    NO_BEREICH = "Ohne Bereich"
    BEREICH_FIELD = "Bereich"
    BEREICHE = {
      "ada-main" => "ADA MAIN",
      "nuova-ai-solutions" => "Nuova AI Solutions",
      "nuovagen" => "NuovaGen"
    }.freeze
    REASONS = %i[waiting question start stale].freeze

    def self.load(user:, params:, now: Time.current, snapshots: nil)
      new(user, params, now, snapshots).load
    end

    attr_reader :tiles, :snapshots

    def initialize(user, params, now, snapshots)
      @user = user
      @raw = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @now = now
      @snapshots = snapshots || DashboardSnapshots.read_all(now:)
    end

    def load
      data = Rails.cache.fetch(["flightplan-dashboard", @user.id], expires_in: CACHE_SECONDS.seconds) { compute }
      @rows = data[:rows]
      @tiles = data[:tiles]
      self
    end

    # Bereichsschlüssel aus dem Parameter; unbekannte Werte zählen als "alle".
    def selected_bereich
      key = @raw["bereich"].to_s.strip
      BEREICHE.key?(key) ? key : nil
    end

    def bereich_choices
      BEREICHE.map do |key, label|
        { key:, label:, count: @rows.count { |row| row[:bereich] == label }, selected: key == selected_bereich }
      end
    end

    def total_count
      @rows.size
    end

    # Gruppen nach Bereich, in fester Reihenfolge; innerhalb nach Alter absteigend. Leere Gruppen entfallen,
    # sofern ein Bereich gewählt ist, bleibt nur dieser (auch leer, damit die Seite es sagt).
    def groups
      labels = BEREICHE.values + [NO_BEREICH]
      shown = selected_bereich ? [BEREICHE[selected_bereich]] : labels
      shown.filter_map do |label|
        rows = @rows.select { |row| row[:bereich] == label }
        next if rows.empty? && !selected_bereich

        { label:, rows: rows.sort_by { |row| [-row[:age_seconds], -row[:id]] } }
      end
    end

    def self.age_label(seconds)
      seconds = seconds.to_i
      return "#{seconds / 86_400} T" if seconds >= 86_400
      return "#{seconds / 3600} Std." if seconds >= 3600

      "#{[seconds / 60, 1].max} Min."
    end

    private

    def compute
      bereiche = project_bereiche
      { rows: attention_rows(bereiche), tiles: build_tiles(bereiche) }
    end

    # project_id => { identifier:, name:, bereich: }
    def projects_by_id
      @projects_by_id ||= Project.visible(@user).pluck(:id, :identifier, :name).to_h do |id, identifier, name|
        [id, { identifier:, name: }]
      end
    end

    def project_bereiche
      field = ProjectCustomField.find_by(name: BEREICH_FIELD)
      labels = {}
      if field
        options = field.custom_options.pluck(:id, :value).to_h { |id, value| [id.to_s, value] }
        CustomValue.where(customized_type: "Project", custom_field_id: field.id, customized_id: projects_by_id.keys)
          .pluck(:customized_id, :value).each { |project_id, value| labels[project_id] = options[value.to_s] }
      end
      projects_by_id.keys.to_h { |id| [id, BEREICHE.value?(labels[id]) ? labels[id] : NO_BEREICH] }
    end

    def attention_rows(bereiche)
      oldest_questions = Flightplan::Question.open.group(:work_package_id).minimum(:created_at)
      cut = @now - STALE_DAYS.days
      found = WorkPackage.visible(@user).joins(:status)
        .where(statuses: { is_closed: false })
        .where(
          "statuses.name IN (:names) OR (statuses.name = :progress AND work_packages.updated_at < :cut) " \
          "OR work_packages.id IN (:question_ids)",
          names: [STATUS_WAITING, STATUS_START], progress: STATUS_PROGRESS, cut:, question_ids: oldest_questions.keys
        )
        .pluck("work_packages.id", "work_packages.subject", "work_packages.project_id", "statuses.name",
               "work_packages.assigned_to_id", "work_packages.updated_at")
      agents = assignee_names(found.filter_map { |row| row[4] })
      found.filter_map do |id, subject, project_id, status, assignee_id, updated_at|
        project = projects_by_id[project_id]
        next unless project

        row_for(id, subject, project, bereiche[project_id], status, agents[assignee_id], updated_at,
                oldest_questions[id], cut)
      end
    end

    def row_for(id, subject, project, bereich, status, agent, updated_at, question_at, cut)
      reasons = []
      stamps = []
      if status == STATUS_WAITING
        reasons << :waiting
        stamps << updated_at
      end
      if question_at
        reasons << :question
        stamps << question_at
      end
      if status == STATUS_START
        reasons << :start
        stamps << updated_at
      end
      if status == STATUS_PROGRESS && updated_at < cut
        reasons << :stale
        stamps << updated_at
      end
      since = stamps.min
      {
        id:, subject:, project: project[:name], project_identifier: project[:identifier], bereich:, status:,
        agent:, reasons:, since:, age_seconds: [(@now - since).to_i, 0].max
      }
    end

    def assignee_names(ids)
      User.where(id: ids.uniq).pluck(:id, :firstname, :lastname, :login).to_h do |id, first, last, login|
        [id, [first, last].compact_blank.join(" ").presence || login]
      end
    end

    def build_tiles(bereiche)
      scope = WorkPackage.visible(@user).joins(:status).where(statuses: { is_closed: false })
      open = scope.group(:project_id).count
      blocked = scope.where(statuses: { name: STATUS_WAITING }).group(:project_id).count
      progress = scope.where(statuses: { name: STATUS_PROGRESS }).group(:project_id).count
      (BEREICHE.values + [NO_BEREICH]).filter_map do |label|
        ids = projects_by_id.keys.select { |id| bereiche[id] == label }
        next if ids.empty?

        {
          label:,
          open: ids.sum { |id| open[id].to_i },
          blocked: ids.sum { |id| blocked[id].to_i },
          in_progress: ids.sum { |id| progress[id].to_i },
          projects: ids.map do |id|
            { identifier: projects_by_id[id][:identifier], name: projects_by_id[id][:name],
              open: open[id].to_i, blocked: blocked[id].to_i }
          end.sort_by { |project| [-project[:open], project[:name].downcase] }
        }
      end
    end
  end
end
