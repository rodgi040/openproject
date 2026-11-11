# frozen_string_literal: true

module Flightplan
  # OP#1839: Karte „Ergebnis zur Abnahme“ im Abschnitt „Braucht dich“. Nur Tickets, die der Nutzer sehen darf und die
  #   (a) eine offene Annahme haben oder
  #   (b) im Status Review stehen UND eine Abschlussaussage tragen (Review ohne Abschlussaussage zählt nicht).
  # Reihenfolge: zuerst (a), dann (b), jeweils älteste zuerst (Zeitpunkt der ältesten offenen Annahme bzw. der
  # Abschlussaussage, dann Ticketnummer). Alles kommt aus den Daten des Moduls:
  #   - PR: Kommentar „PR: <url>“, den `fp-op link-pr` schreibt (neuester gewinnt, mit Autor und Zeit);
  #   - Abschlussaussage: neuester Kommentar, dessen erste Zeile <!-- fp-result v1 --> ist (`fp-op result`);
  #   - Annahmen: Flightplan::Assumption.
  # Merge-Guard und Diff-Größe kennt das Modul nicht; sie werden nicht angezeigt.
  module Acceptance
    MARKER = "<!-- fp-result v1 -->"
    SECTIONS = { "Geändert" => :changed, "Geprüft" => :checked, "Offen" => :open_points }.freeze
    SECTION_LIMIT = 1500
    LIMIT = 50
    REVIEW_STATUS = "Review"
    PR_NOTE = /\APR:[ \t]*(https?:\/\/[^\s<>"']+)[ \t]*\z/
    # Gleiche Bedingung wie PR_NOTE, für die Vorauswahl in der Datenbank (Zeile beginnt mit „PR: http“).
    PR_SQL = "(^|\n)PR:[[:blank:]]*https?://[^[:space:]<>\"']+[[:space:]]*($|\n)"

    Result = Struct.new(:changed, :checked, :open_points, :at, :by, keyword_init: true)
    Row = Struct.new(:work_package, :id, :subject, :status, :project, :review, :since, :pull_request, :pull_request_by,
                     :pull_request_at, :result, :assumptions, keyword_init: true)
    # rows: die angezeigten Zeilen (höchstens LIMIT); total: alle Karten, die zählen.
    List = Struct.new(:rows, :total, keyword_init: true) do
      def more
        total - rows.size
      end

      def size
        total
      end

      def any?
        total.positive?
      end
    end

    module_function

    def load(user:)
      visible = WorkPackage.visible(user)
      assumed = assumed_ids(visible)
      review = visible.joins(:status).where(statuses: { name: REVIEW_STATUS }).where.not(id: assumed).select("work_packages.id")
      results = latest_notes(review) { |scope| marker_scope(scope) }
      with_result = results.sort_by { |id, note| [note.created_at, id] }.map(&:first)
      ids = assumed + with_result
      shown = ids.first(LIMIT)
      return List.new(rows: [], total: ids.size) if shown.empty?

      results = results.merge(latest_notes(shown - results.keys) { |scope| marker_scope(scope) })
      prs = latest_notes(shown) { |scope| scope.where("journals.notes ~ ?", PR_SQL) }
      work_packages = WorkPackage.visible(user).where(id: shown).includes(:project, :status).index_by(&:id)
      assumptions = Assumption.open.where(work_package_id: shown).oldest_first.includes(:author).group_by(&:work_package_id)
      users = User.where(id: (results.values + prs.values).map(&:user_id).compact.uniq).index_by(&:id)
      rows = shown.filter_map do |id|
        next unless work_packages[id]

        row_for(work_packages[id], assumptions[id].to_a, results[id], prs[id], users)
      end
      List.new(rows:, total: ids.size)
    end

    # Erste Zeile exakt der Marker; sonst kein Ergebnis. Die Abschnitte sind reiner Text (die Ansicht escaped).
    def parse_result(text, at: nil, by: nil)
      lines = text.to_s.delete("\r").lstrip.lines.map(&:chomp)
      return unless lines.first.to_s.strip == MARKER

      parts = {}
      current = nil
      lines.drop(1).each do |line|
        heading = line.match(/\A##[ \t]+(\S+)[ \t]*\z/)
        if heading && SECTIONS.key?(heading[1])
          current = SECTIONS[heading[1]]
          parts[current] = []
        elsif current
          parts[current] << line
        end
      end
      Result.new(**SECTIONS.values.to_h { |key| [key, parts[key].to_a.join("\n").strip.truncate(SECTION_LIMIT)] }, at:, by:)
    end

    def pull_request_in(note)
      note.to_s.lines.each do |line|
        match = line.strip.match(PR_NOTE)
        return match[1] if match
      end
      nil
    end

    # Tickets mit offener Annahme, sichtbar, älteste Annahme zuerst (deterministisch: Zeit, dann Ticketnummer).
    def assumed_ids(visible)
      Assumption.open.joins(:work_package).merge(visible)
        .group("flightplan_assumptions.work_package_id")
        .order(Arel.sql("MIN(flightplan_assumptions.created_at), flightplan_assumptions.work_package_id"))
        .pluck("flightplan_assumptions.work_package_id")
    end

    def marker_scope(scope)
      scope.where("journals.notes = ? OR journals.notes LIKE ? OR journals.notes LIKE ?",
                  MARKER, "#{MARKER}\n%", "#{MARKER}\r\n%")
    end

    # Je Ticket nur der neueste Kommentar, der die Bedingung erfüllt; nur Kommentare der angegebenen Tickets.
    def latest_notes(ticket_ids_or_relation)
      return {} if ticket_ids_or_relation.is_a?(Array) && ticket_ids_or_relation.empty?

      scope = Journal.where(journable_type: "WorkPackage", journable_id: ticket_ids_or_relation)
      scope = scope.where(internal: false) if Journal.column_names.include?("internal")
      scope = yield(scope)
      scope.select("DISTINCT ON (journals.journable_id) journals.id, journals.journable_id, journals.user_id, " \
                   "journals.notes, journals.created_at")
        .order(Arel.sql("journals.journable_id, journals.id DESC"))
        .index_by(&:journable_id)
    end

    def row_for(work_package, assumptions, result_note, pr_note, users)
      result = result_note && parse_result(result_note.notes, at: result_note.created_at, by: users[result_note.user_id]&.name)
      pull_request = pr_note && pull_request_in(pr_note.notes)
      since = assumptions.first&.created_at || result&.at || work_package.updated_at
      Row.new(
        work_package:, id: work_package.id, subject: work_package.subject, status: work_package.status.name,
        project: work_package.project.name, review: work_package.status.name == REVIEW_STATUS, since:,
        pull_request:, pull_request_by: (users[pr_note.user_id]&.name if pull_request),
        pull_request_at: (pr_note.created_at if pull_request), result:, assumptions:
      )
    end
  end
end
