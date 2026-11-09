# frozen_string_literal: true

module Flightplan
  # OP#1711 Wave 2: Ereignisse eines Tickets für den Verlauf im Chat-Thread (Kommentare, Statuswechsel, Rückfragen).
  # Nur Anzeige: Der Chat rendert sie als Systemzeilen und gibt sie nie als Anweisung an den Agent weiter. Texte sind
  # Fremdtext (untrusted) und werden gekürzt; HTML bleibt Text. Jedes Ereignis trägt eine stabile Id (c<journal>,
  # s<journal>, q<frage>), damit wiederholtes Abfragen und Neuladen keine Dubletten erzeugen.
  class ChatEvents
    # Der Marker steht am Anfang eines Kommentars, der aus dem Chat entstand (Chat::Comment schreibt ihn).
    MARKER = "[aus Chat]"
    TEXT_LIMIT = 600
    LIMIT = 30
    SCAN_LIMIT = 80

    class << self
      # after_journal / after_question: höchste bereits bekannte Id (Cursor); ohne Angabe die letzten Ereignisse.
      def load(user:, work_package:, after_journal: nil, after_question: nil)
        journals = journal_events(user, work_package, after_journal.to_i)
        questions = question_events(work_package, after_question.to_i)
        events = (journals[:events] + questions[:events]).sort_by { |event| [event[:at], event[:id]] }.last(LIMIT)
        { events:, cursor: { journal: journals[:cursor], question: questions[:cursor] } }
      end

      def chat_comment?(notes)
        notes.to_s.start_with?(MARKER)
      end

      private

      def journal_events(user, work_package, after)
        scope = work_package.journals.where("journals.notes <> '' OR journals.version > 1")
        scope = scope.where("journals.id > ?", after) if after.positive?
        journals = scope.order(id: :desc).limit(SCAN_LIMIT).includes(:user).to_a.reverse
        names = status_names(journals)
        events = journals.select { |journal| journal.visible?(user) }.flat_map { |journal| events_of(journal, names) }
        { events:, cursor: [after, journals.map(&:id).max.to_i].max }
      end

      def events_of(journal, names)
        list = []
        notes = journal.notes.to_s
        if notes.present?
          chat = chat_comment?(notes)
          text = chat ? notes.delete_prefix(MARKER).strip : notes
          list << base(journal, "c#{journal.id}", "comment").merge(text: text.truncate(TEXT_LIMIT), source: chat ? "chat" : nil)
        end
        change = journal.details["status_id"]
        if change
          list << base(journal, "s#{journal.id}", "status").merge(from: names[change.first].to_s, to: names[change.last].to_s)
        end
        list
      end

      def base(journal, id, kind)
        { id:, kind:, at: journal.created_at.utc.iso8601, author: journal.user&.login.to_s }
      end

      def status_names(journals)
        ids = journals.flat_map { |journal| Array(journal.details["status_id"]) }.compact.uniq
        ids.empty? ? {} : Status.where(id: ids).pluck(:id, :name).to_h
      end

      def question_events(work_package, after)
        scope = Question.where(work_package_id: work_package.id).includes(:author)
        scope = scope.where("flightplan_questions.id > ?", after) if after.positive?
        questions = scope.order(id: :desc).limit(LIMIT).to_a.reverse
        events = questions.map do |question|
          { id: "q#{question.id}", kind: "question", at: question.created_at.utc.iso8601, author: question.author&.login.to_s,
            text: question.question.to_s.truncate(TEXT_LIMIT), source: nil }
        end
        { events:, cursor: [after, questions.map(&:id).max.to_i].max }
      end
    end
  end
end
