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
    # Gründe, die in der Statusspalte als eigener Hinweis erscheinen. "Wartet auf Mensch" und "Startfreigabe"
    # sagt schon der Status selbst.
    REASONS = %i[question stale start_failed].freeze
    FAILED_START_DAYS = 14
    # Marker des Pollers (op_poller: <!-- fp-op-alarm:start:N -->) und Rückfall-Kommentar von ada-dispatch.
    FAILED_START_NOTES = ["%fp-op-alarm:start:%", "%ada-dispatch: Start fehlgeschlagen%"].freeze
    # Freigabe: von diesen Status auf Startfreigabe, nur bei Master "op".
    APPROVABLE_STATUSES = ["Geplant", STATUS_WAITING].freeze
    MASTER_FIELD = "Master"
    LABELS_FIELD = "Labels"
    STATUS_IDS_CACHE_SECONDS = 300
    STATUS_IDS_CACHE_KEY = "flightplan-dashboard-status-ids"
    REQUIRED_STATUSES = [STATUS_WAITING, STATUS_START, STATUS_PROGRESS, *APPROVABLE_STATUSES].uniq.freeze
    # Nur diese Konten zählen als Absender der Startfehler-Notizen (ada-dispatch nutzt per fp-op `dispatcher`,
    # siehe openproject/orchestrator/README.md). Notizen anderer Autoren lösen keinen Alarm aus.
    FAILED_START_AUTHORS = %w[dispatcher].freeze
    # Version im Cache-Schlüssel: Ändert sich die Form der gecachten Daten, liest kein Prozess alte Einträge.
    CACHE_VERSION = 2

    def self.cache_key(user_id)
      ["flightplan-dashboard", CACHE_VERSION, user_id]
    end

    def self.load(user:, params:, now: Time.current, snapshots: nil)
      new(user, params, now, snapshots).load
    end

    attr_reader :tiles, :snapshots, :running, :missing_statuses, :project_tree, :status_order

    def initialize(user, params, now, snapshots)
      @user = user
      @raw = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @now = now
      @snapshots = snapshots || DashboardSnapshots.read_all(now:)
    end

    def load
      key = self.class.cache_key(@user.id)
      data = Rails.cache.read(key)
      if data.nil?
        data = compute
        # Fehlt ein Statusname, wird nichts gecacht (die Seite warnt und rechnet bei jedem Aufruf neu).
        Rails.cache.write(key, data, expires_in: CACHE_SECONDS.seconds) if data[:missing_statuses].empty?
      end
      @rows = data[:rows]
      @tiles = data[:tiles]
      @running = data[:running]
      @missing_statuses = data[:missing_statuses] || []
      @project_tree = data[:project_tree]
      @status_order = data[:status_order]
      self
    end

    # Bereichsschlüssel aus dem Parameter; unbekannte Werte zählen als "alle".
    def selected_bereich
      key = @raw["bereich"].to_s.strip
      BEREICHE.key?(key) ? key : nil
    end

    # Nicht leerer, aber unbekannter Bereichsschlüssel (für den Hinweis); gekürzt, damit die Seite stabil bleibt.
    def unknown_bereich
      key = @raw["bereich"].to_s.strip
      return nil if key.empty? || BEREICHE.key?(key)

      key.truncate(60)
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

    # Die Status-IDs werden einmal per Name aufgelöst und kurz gecacht (Status werden selten umbenannt).
    # Fehlt ein Name (Umbenennung), wird nichts gecacht: die nächste Seite löst neu auf, sobald er wieder da ist,
    # und die Seite warnt sichtbar.
    def self.status_lookup
      cached = Rails.cache.read(STATUS_IDS_CACHE_KEY)
      return cached if cached

      ids = Status.where(name: REQUIRED_STATUSES).pluck(:name, :id).to_h
      lookup = { ids:, missing: REQUIRED_STATUSES - ids.keys }
      Rails.cache.write(STATUS_IDS_CACHE_KEY, lookup, expires_in: STATUS_IDS_CACHE_SECONDS.seconds) if lookup[:missing].empty?
      lookup
    end

    def self.status_ids
      status_lookup[:ids]
    end

    def self.missing_statuses
      status_lookup[:missing]
    end

    # Für dashboard-check.sh (H2): offene Arbeitspakete je Status und die Kachelzahlen derselben Seite.
    def self.check_report(user:, now: Time.current)
      dashboard = load(user:, params: {}, now:)
      statuses = WorkPackage.visible(user).joins(:status).where(statuses: { is_closed: false })
        .group("statuses.name").count
      {
        statuses:,
        missing_statuses: dashboard.missing_statuses,
        total_open: statuses.values.sum,
        tiles: dashboard.tiles.to_h { |tile| [tile[:label], { open: tile[:open], blocked: tile[:blocked] }] }
      }
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
      running = running_agents(bereiche)
      { rows: attention_rows(bereiche), tiles: build_tiles(bereiche, running), running:,
        missing_statuses: self.class.missing_statuses,
        project_tree: tree_order.map { |entry| entry.merge(bereich: bereiche[entry[:id]]) },
        status_order: Status.order(:position).pluck(:name) }
    end

    # project_id => { identifier:, name:, parent_id: }
    def projects_by_id
      @projects_by_id ||= Project.visible(@user).pluck(:id, :identifier, :name, :parent_id).to_h do |id, identifier, name, parent_id|
        [id, { identifier:, name:, parent_id: }]
      end
    end

    # Sichtbare Projekte in Baumreihenfolge (Kinder nach Name), mit Tiefe und Pfad (eigener Identifier zuerst, dann die
    # Vorfahren). Ein Projekt, dessen Elternprojekt nicht sichtbar ist, steht oben.
    def tree_order
      @tree_order ||= begin
        children = {}
        projects_by_id.each do |id, project|
          parent = projects_by_id.key?(project[:parent_id]) ? project[:parent_id] : nil
          (children[parent] ||= []) << id
        end
        order = []
        walk = lambda do |parent, depth, path|
          Array(children[parent]).sort_by { |id| [projects_by_id[id][:name].downcase, id] }.each do |id|
            own = [projects_by_id[id][:identifier], *path]
            order << { id:, identifier: own.first, name: projects_by_id[id][:name], depth:, path: own }
            walk.(id, depth + 1, own)
          end
        end
        walk.(nil, 0, [])
        order
      end
    end

    def project_paths
      @project_paths ||= tree_order.to_h { |entry| [entry[:id], entry[:path]] }
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
      ids = self.class.status_ids
      found = WorkPackage.visible(@user).joins(:status)
        .where(statuses: { is_closed: false })
        .where(
          "work_packages.status_id IN (:names) OR (work_packages.status_id = :progress AND work_packages.updated_at < :cut) " \
          "OR work_packages.id IN (:question_ids)",
          names: ids.values_at(STATUS_WAITING, STATUS_START).compact, progress: ids[STATUS_PROGRESS], cut:,
          question_ids: oldest_questions.keys
        )
        .pluck("work_packages.id", "work_packages.subject", "work_packages.project_id", "work_packages.status_id",
               "work_packages.assigned_to_id", "work_packages.updated_at", "work_packages.lock_version")
      wp_ids = found.map(&:first)
      changed = status_changed_at(wp_ids)
      waiting_ids = found.select { |row| row[3] == ids[STATUS_WAITING] }
      context = {
        labels: work_package_labels(wp_ids),
        agents: assignee_names(found.filter_map { |row| row[4] }),
        status_names: Status.where(id: found.map { |row| row[3] }.uniq).pluck(:id, :name).to_h,
        changed:,
        failed: failed_starts(waiting_ids.to_h { |row| [row[0], changed[row[0]] || row[5]] }),
        masters: masters(wp_ids),
        ids:
      }
      found.filter_map do |id, subject, project_id, status_id, assignee_id, updated_at, lock_version|
        project = projects_by_id[project_id]
        next unless project

        row_for(
          { id:, subject:, project_id:, status_id:, assignee_id:, updated_at:, lock_version: },
          project, bereiche[project_id], oldest_questions[id], cut, context
        )
      end
    end

    def row_for(wp, project, bereich, question_at, cut, context)
      status = context[:status_names][wp[:status_id]]
      since_status = context[:changed][wp[:id]] || wp[:updated_at]
      reasons = []
      stamps = []
      if question_at
        reasons << :question
        stamps << question_at
      end
      if wp[:status_id] == context[:ids][STATUS_WAITING] || wp[:status_id] == context[:ids][STATUS_START]
        stamps << since_status
      end
      if wp[:status_id] == context[:ids][STATUS_PROGRESS] && wp[:updated_at] < cut
        reasons << :stale
        stamps << since_status
      end
      if context[:failed].key?(wp[:id])
        reasons << :start_failed
        stamps << since_status
      end
      since = stamps.min || since_status
      approvable = APPROVABLE_STATUSES.include?(status) && context[:masters][wp[:id]] == "op"
      {
        id: wp[:id], subject: wp[:subject], project: project[:name], project_identifier: project[:identifier],
        project_path: project_paths[wp[:project_id]] || [project[:identifier]], labels: context[:labels][wp[:id]] || [],
        bereich:, status:, agent: context[:agents][wp[:assignee_id]], reasons:, since:,
        age_seconds: [(@now - since).to_i, 0].max, lock_version: wp[:lock_version], approvable:
      }
    end

    # Zeitpunkt des letzten Statuswechsels je Arbeitspaket aus den Journalen, eine einzige Abfrage für alle IDs
    # (kein N+1). Zählt als Wechsel: das erste Journal und jedes Journal, dessen status_id vom Vorgänger abweicht.
    def status_changed_at(wp_ids)
      return {} if wp_ids.empty?

      sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, wp_ids])
        SELECT journable_id, MAX(created_at) AS changed_at
        FROM (
          SELECT journals.journable_id, journals.created_at, work_package_journals.status_id,
                 LAG(work_package_journals.status_id) OVER (
                   PARTITION BY journals.journable_id ORDER BY journals.version ASC, journals.id ASC
                 ) AS previous_status_id
          FROM journals
          INNER JOIN work_package_journals
            ON work_package_journals.id = journals.data_id
           AND journals.data_type = 'Journal::WorkPackageJournal'
          WHERE journals.journable_type = 'WorkPackage' AND journals.journable_id IN (?)
        ) status_history
        WHERE previous_status_id IS NULL OR previous_status_id <> status_id
        GROUP BY journable_id
      SQL
      ActiveRecord::Base.connection.select_all(sql).cast_values.to_h do |id, changed_at|
        [id, changed_at.is_a?(String) ? Time.zone.parse(changed_at) : changed_at.in_time_zone]
      end
    end

    # "Start fehlgeschlagen" (H4): Alarm- oder Rückfall-Kommentar der letzten 14 Tage in den Journal-Notizen,
    # nur von FAILED_START_AUTHORS und nur jünger als der letzte Eintritt in "Wartet auf Mensch"
    # (entered_at je Arbeitspaket). Eine Notiz im Journal des Eintritts selbst zählt mit (gleicher Zeitpunkt).
    def failed_starts(entered_at)
      return {} if entered_at.empty?

      notes = Journal.joins(:user)
        .where(journable_type: "WorkPackage", journable_id: entered_at.keys, users: { login: FAILED_START_AUTHORS })
        .where("journals.created_at >= ?", @now - FAILED_START_DAYS.days)
        .where("journals.notes LIKE ? OR journals.notes LIKE ?", *FAILED_START_NOTES)
        .pluck(:journable_id, "journals.created_at")
      notes.each_with_object({}) do |(id, at), found|
        next if at < entered_at[id]

        found[id] = [found[id], at].compact.max
      end
    end

    # Custom field "Master" (github | op) je Arbeitspaket, eine Abfrage.
    def masters(wp_ids)
      field = WorkPackageCustomField.find_by(name: MASTER_FIELD)
      return {} if field.nil? || wp_ids.empty?

      options = field.custom_options.pluck(:id, :value).to_h { |id, value| [id.to_s, value] }
      CustomValue.where(customized_type: "WorkPackage", custom_field_id: field.id, customized_id: wp_ids)
        .pluck(:customized_id, :value).to_h { |id, value| [id, options[value.to_s]] }
    end

    def labels_field
      return @labels_field if defined?(@labels_field)

      @labels_field = WorkPackageCustomField.find_by(name: LABELS_FIELD)
    end

    def label_names
      @label_names ||= labels_field ? labels_field.custom_options.pluck(:id, :value).to_h { |id, value| [id.to_s, value] } : {}
    end

    # Labels je Arbeitspaket in der Reihenfolge der Zuordnung, eine Abfrage.
    def work_package_labels(wp_ids)
      return {} if labels_field.nil? || wp_ids.empty?

      CustomValue.where(customized_type: "WorkPackage", custom_field_id: labels_field.id, customized_id: wp_ids)
        .order(:id).pluck(:customized_id, :value).each_with_object({}) do |(id, value), found|
          name = label_names[value.to_s]
          (found[id] ||= []) << name if name.present?
        end
    end

    # Labels der offenen Arbeitspakete je Projekt, eine Abfrage.
    def project_labels(scope)
      return {} if labels_field.nil?

      scope.joins("INNER JOIN custom_values fp_labels ON fp_labels.customized_type = 'WorkPackage' " \
                  "AND fp_labels.customized_id = work_packages.id")
        .where("fp_labels.custom_field_id = ?", labels_field.id).distinct
        .pluck("work_packages.project_id", "fp_labels.value").each_with_object({}) do |(project_id, value), found|
          name = label_names[value.to_s]
          (found[project_id] ||= []) << name if name.present?
        end
        .transform_values { |names| names.uniq.sort_by(&:downcase) }
    end

    def assignee_names(ids)
      User.where(id: ids.uniq).pluck(:id, :firstname, :lastname, :login).to_h do |id, first, last, login|
        [id, [first, last].compact_blank.join(" ").presence || login]
      end
    end

    # Laufende Agents (H5): Starts aus dispatch.json (letzte_starts), deren Ticket jetzt "In Arbeit" ist.
    # nil, wenn dispatch.json fehlt oder unbrauchbar ist ("nicht aktiv").
    def running_agents(bereiche)
      source = @snapshots[:dispatch]
      return nil if source.inactive?

      starts = Array(source.data["letzte_starts"]).filter_map do |entry|
        op = entry.is_a?(Hash) ? Integer(entry["op"], exception: false) : nil
        [op, entry] if op&.positive?
      end.to_h
      progress_id = self.class.status_ids[STATUS_PROGRESS]
      return [] if starts.empty? || progress_id.nil?

      found = WorkPackage.visible(@user).where(id: starts.keys.first(200), status_id: progress_id)
        .pluck(:id, :subject, :project_id)
      labels = work_package_labels(found.map(&:first))
      found.filter_map do |id, subject, project_id|
        project = projects_by_id[project_id]
        next unless project

        entry = starts[id]
        { id:, subject:, project_id:, project: project[:name], bereich: bereiche[project_id],
          project_path: project_paths[project_id] || [project[:identifier]], labels: labels[id] || [],
          status: STATUS_PROGRESS, harness: entry["harness"].to_s.truncate(40),
          model: entry["modell"].to_s.truncate(60).presence, started: parse_time(entry["gestartet"]) }
      end
    end

    def parse_time(value)
      Time.iso8601(value.to_s).in_time_zone
    rescue ArgumentError, TypeError
      nil
    end

    def build_tiles(bereiche, running)
      scope = WorkPackage.visible(@user).joins(:status).where(statuses: { is_closed: false })
      ids = self.class.status_ids
      open = scope.group(:project_id).count
      blocked = scope.where(work_packages: { status_id: ids[STATUS_WAITING] }).group(:project_id).count
      progress = scope.where(work_packages: { status_id: ids[STATUS_PROGRESS] }).group(:project_id).count
      questions = open_questions_by_project(scope)
      statuses = open_statuses_by_project(scope)
      labels = project_labels(scope)
      (BEREICHE.values + [NO_BEREICH]).filter_map do |label|
        project_ids = tree_order.filter_map { |entry| entry[:id] if bereiche[entry[:id]] == label }
        next if project_ids.empty?

        {
          label:, key: BEREICHE.key(label),
          project_count: project_ids.size,
          open: project_ids.sum { |id| open[id].to_i },
          blocked: project_ids.sum { |id| blocked[id].to_i },
          in_progress: project_ids.sum { |id| progress[id].to_i },
          questions: project_ids.sum { |id| questions[id].to_i },
          agents: running && running.count { |entry| project_ids.include?(entry[:project_id]) },
          projects: project_ids.map do |id|
            path = project_paths[id]
            { identifier: projects_by_id[id][:identifier], name: projects_by_id[id][:name],
              open: open[id].to_i, blocked: blocked[id].to_i, path:,
              depth: path.drop(1).count { |identifier| bereiche[project_id_for(identifier)] == label },
              statuses: statuses[id] || [], labels: labels[id] || [] }
          end,
          project_identifiers: project_ids.map { |id| projects_by_id[id][:identifier] }
        }
      end
    end

    def project_id_for(identifier)
      @project_ids_by_identifier ||= projects_by_id.to_h { |id, project| [project[:identifier], id] }
      @project_ids_by_identifier[identifier]
    end

    # Status der offenen Arbeitspakete je Projekt (Statusreihenfolge), eine Abfrage.
    def open_statuses_by_project(scope)
      scope.group(:project_id, "statuses.name", "statuses.position").count.keys
        .sort_by { |_, _, position| position.to_i }
        .each_with_object({}) { |(project_id, name, _), found| (found[project_id] ||= []) << name }
    end

    # Offene Rückfragen je Projekt (nur zu offenen, sichtbaren Arbeitspaketen).
    def open_questions_by_project(scope)
      per_wp = Flightplan::Question.open.group(:work_package_id).count
      return {} if per_wp.empty?

      scope.where(id: per_wp.keys).pluck("work_packages.id", "work_packages.project_id")
        .each_with_object(Hash.new(0)) { |(id, project_id), sum| sum[project_id] += per_wp[id] }
    end
  end
end
