# frozen_string_literal: true

require "digest"

module Flightplan
  # OP#1711 Wave 2: Ereignisse eines Tickets für den Verlauf im Chat-Thread (Kommentare, Statuswechsel, beantwortete
  # Rückfragen). Nur Anzeige: Der Chat rendert sie als Systemzeilen und gibt sie nie als Anweisung an den Agent weiter.
  # Texte sind Fremdtext (untrusted) und werden gekürzt; HTML bleibt Text.
  #
  # Aggregation: OP fasst Journale desselben Nutzers innerhalb von journal_aggregation_time_minutes in das letzte Journal
  # zusammen (Journals::CreateService). Die Journal-Id bleibt gleich, updated_at, Notiz und Details ändern sich. Ein
  # zweiter Kommentar wird nie angehängt: liegt im Vorgänger schon eine Notiz, entsteht ein neues Journal ("only_one_note").
  # Deshalb ist der Cursor (Id, updated_at) und die Ereignis-Id trägt den Inhalt:
  #   c<journal>-<hash(notes)>, s<journal>-<von>-<nach>, q<frage>-<hash(status, antwort)>.
  # Der Teil vor dem ersten "-" ist der Schlüssel der Zeile (c12, s12, q3); eine neue Id mit gleichem Schlüssel ersetzt im
  # Client die ältere Zeile (z. B. zweiter Statuswechsel im selben Journal). Gleiche Ids sind Wiederholungen.
  #
  # Rückfragen: offene Fragen stehen im Formular und fehlen hier. Die Journale, die `fp-op ask` und die Antwort schreiben
  # ("Rückfrage: …", "Rückfrage von …"), werden ausgelassen; eine beantwortete Frage erscheint als eine Zeile (q…).
  class ChatEvents
    # Der Marker steht am Anfang eines Kommentars, der aus dem Chat entstand (Chat::Comment schreibt ihn).
    MARKER = "[aus Chat]"
    QUESTION_NOTE = /\ARückfrage( von [^:\n]*)?:/
    TEXT_LIMIT = 600
    LIMIT = 30
    SCAN_LIMIT = 80

    class << self
      # after_* : Cursor aus der letzten Antwort (Id und updated_at); ohne Angabe die letzten Ereignisse.
      def load(user:, work_package:, after_journal: nil, after_journal_at: nil, after_question: nil, after_question_at: nil)
        journals = journal_events(user, work_package, after_journal.to_i, parse_time(after_journal_at))
        questions = question_events(work_package, after_question.to_i, parse_time(after_question_at))
        events = (journals[:events] + questions[:events]).sort_by { |event| [event[:at], event[:id]] }.last(LIMIT)
        {
          events:,
          cursor: {
            journal: journals[:cursor], journal_at: journals[:cursor_at],
            question: questions[:cursor], question_at: questions[:cursor_at]
          }
        }
      end

      def chat_comment?(notes)
        notes.to_s.start_with?(MARKER)
      end

      def question_note?(notes)
        QUESTION_NOTE.match?(notes.to_s)
      end

      private

      def parse_time(value)
        Time.iso8601(value.to_s).utc if value.present?
      rescue ArgumentError
        nil
      end

      def stamp(time)
        time&.utc&.iso8601(6)
      end

      def digest(*parts)
        Digest::SHA1.hexdigest(parts.join("\u0000"))[0, 8]
      end

      def journal_events(user, work_package, after, after_at)
        scope = work_package.journals.where("journals.notes <> '' OR journals.version > 1")
        # >= : das zuletzt gelesene Journal wird erneut gelesen; ändert es sich nicht, sind die Ids gleich (keine Dublette).
        if after_at
          scope = scope.where("journals.id > ? OR journals.updated_at >= ?", after, after_at)
        elsif after.positive?
          scope = scope.where("journals.id > ?", after)
        end
        journals = scope.order(id: :desc).limit(SCAN_LIMIT).includes(:user).to_a.reverse
        names = status_names(journals)
        events = journals.select { |journal| journal.visible?(user) }.flat_map { |journal| events_of(journal, names) }
        newest = journals.max_by(&:updated_at)
        { events:, cursor: [after, journals.map(&:id).max.to_i].max,
          cursor_at: stamp([after_at, newest&.updated_at].compact.max) }
      end

      def events_of(journal, names)
        list = []
        notes = journal.notes.to_s
        if notes.present? && !question_note?(notes)
          chat = chat_comment?(notes)
          text = chat ? notes.delete_prefix(MARKER).strip : notes
          list << base(journal, "c#{journal.id}-#{digest(notes)}", "comment")
            .merge(text: text.truncate(TEXT_LIMIT), source: chat ? "chat" : nil)
        end
        change = journal.details["status_id"]
        if change
          list << base(journal, "s#{journal.id}-#{change.first.to_i}-#{change.last.to_i}", "status")
            .merge(from: names[change.first].to_s, to: names[change.last].to_s)
        end
        list
      end

      def base(journal, id, kind)
        { id:, kind:, at: journal.updated_at.utc.iso8601, author: journal.user&.login.to_s }
      end

      def status_names(journals)
        ids = journals.flat_map { |journal| Array(journal.details["status_id"]) }.compact.uniq
        ids.empty? ? {} : Status.where(id: ids).pluck(:id, :name).to_h
      end

      # Nur beantwortete Fragen; offene stehen im Formular.
      def question_events(work_package, after, after_at)
        scope = Question.where(work_package_id: work_package.id).includes(:author)
        if after_at
          scope = scope.where("flightplan_questions.id > ? OR flightplan_questions.updated_at >= ?", after, after_at)
        elsif after.positive?
          scope = scope.where("flightplan_questions.id > ?", after)
        end
        questions = scope.order(id: :desc).limit(LIMIT).to_a.reverse
        events = questions.reject(&:open?).map { |question| question_event(question) }
        newest = questions.max_by(&:updated_at)
        { events:, cursor: [after, questions.map(&:id).max.to_i].max,
          cursor_at: stamp([after_at, newest&.updated_at].compact.max) }
      end

      def question_event(question)
        given = question.chosen_option.presence || question.answer.to_s
        text = "#{question.question} – Antwort: #{given}".squish
        { id: "q#{question.id}-#{digest(question.status, given)}", kind: "question",
          at: (question.answered_at || question.updated_at).utc.iso8601,
          author: question.author&.login.to_s, text: text.truncate(TEXT_LIMIT), source: nil }
      end
    end
  end
end
