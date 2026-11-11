# frozen_string_literal: true

module Flightplan
  # OP#1839: Karte „Ergebnis zur Abnahme“ im Abschnitt „Braucht dich“. Tickets im Status Review und Tickets mit offener
  # Annahme, soweit der Nutzer sie sehen darf. Alles kommt aus den Daten des Moduls:
  #   - PR: der Kommentar „PR: <url>“, den `fp-op link-pr` schreibt (neuester gewinnt);
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

    Result = Struct.new(:changed, :checked, :open_points, :at, keyword_init: true)
    Row = Struct.new(:work_package, :id, :subject, :status, :project, :review, :since, :pull_request, :result,
                     :assumptions, keyword_init: true)

    module_function

    def load(user:)
      ids = candidate_ids(user)
      return [] if ids.empty?

      work_packages = WorkPackage.visible(user).where(id: ids).includes(:project, :status).index_by(&:id)
      assumptions = Assumption.open.where(work_package_id: ids).oldest_first.includes(:author).group_by(&:work_package_id)
      notes = notes_for(ids)
      ids.filter_map do |id|
        work_package = work_packages[id]
        next unless work_package

        row_for(work_package, assumptions[id].to_a, notes[id].to_a)
      end.sort_by { |row| [row.since, row.id] }
    end

    # Erste Zeile exakt der Marker; sonst kein Ergebnis. Die Abschnitte sind reiner Text (die Ansicht escaped).
    def parse_result(text, at: nil)
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
      Result.new(**SECTIONS.values.to_h { |key| [key, parts[key].to_a.join("\n").strip.truncate(SECTION_LIMIT)] }, at:)
    end

    def pull_request_in(note)
      note.to_s.lines.each do |line|
        match = line.strip.match(PR_NOTE)
        return match[1] if match
      end
      nil
    end

    def candidate_ids(user)
      review = WorkPackage.visible(user).joins(:status).where(statuses: { name: REVIEW_STATUS }).pluck(:id)
      assumed = Assumption.open.joins(:work_package).merge(WorkPackage.visible(user)).pluck(:work_package_id)
      (review + assumed).uniq.first(LIMIT)
    end

    # Neueste zuerst; nur Kommentare, die Marker oder PR-Zeile enthalten können.
    def notes_for(ids)
      scope = Journal.where(journable_type: "WorkPackage", journable_id: ids).where.not(notes: [nil, ""])
      scope = scope.where(internal: false) if Journal.column_names.include?("internal")
      scope = scope.where("journals.notes LIKE ? OR journals.notes LIKE ?", "%fp-result v1%", "%PR:%")
      scope.order(id: :desc).select(:id, :journable_id, :notes, :created_at).group_by(&:journable_id)
    end

    def row_for(work_package, assumptions, notes)
      result_note = notes.find { |note| parse_result(note.notes) }
      pr_note = notes.lazy.map { |note| pull_request_in(note.notes) }.find(&:present?)
      since = [assumptions.first&.created_at, result_note&.created_at].compact.min || work_package.updated_at
      Row.new(
        work_package:, id: work_package.id, subject: work_package.subject, status: work_package.status.name,
        project: work_package.project.name, review: work_package.status.name == REVIEW_STATUS, since:,
        pull_request: pr_note,
        result: result_note && parse_result(result_note.notes, at: result_note.created_at),
        assumptions:
      )
    end
  end
end
