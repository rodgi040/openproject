# frozen_string_literal: true

module Flightplan
  # OP#1843: Die Regel SHADOW_RULE_V1. Sie sagt nur, ob eine Frage ein Kandidat für eine spätere Selbstentscheidung WÄRE;
  # sie entscheidet nichts. Nichts im Modul ruft sie auf, um eine Rückfrage oder Chat-Anfrage zu beantworten.
  #
  # Konservativ und fail-closed: `would_auto` ist nur dann wahr, wenn ALLE Bedingungen zutreffen:
  #   1. source = ask (Rückfrage über fp-op ask; Chat-Fragen beobachtet der Server nicht, sie sind in V1 nie wahr)
  #   2. kind = entscheidung
  #   3. reversible = true (nil = unbekannt zählt als nein)
  #   4. eine Empfehlung liegt vor
  #   5. weder Frage noch Optionen noch Kontext enthalten ein Wort der Vorbehaltsliste (RESERVED_WORDS)
  # Fehlt etwas oder ist es unlesbar, ist das Ergebnis falsch. `reason` nennt den ersten Grund für „nein“.
  #
  # Wortliste: Groß-/Kleinschreibung egal, deutsch und englisch. Ein Treffer braucht eine Wortgrenze davor (Buchstaben davor
  # zählen nicht: „Transport“ ist kein „Port“). Nach rechts sind die Stämme offen: „Host“ trifft „Hostname“, „Port“ trifft
  # „Portfreigabe“ (und absichtlich auch „Portal“, „Portierung“: ein falsches Nein kostet nur Messbreite, keine Ausnahmenliste).
  # Nur `main` und `prod` sind Ganzwörter (mit Endung s, e, en, n, er, es, ern, ing, ed), weil sie sonst fast jedes Wort treffen
  # („maintain“, „Produkt“); für deren Zusammensetzungen stehen eigene Einträge (produktiv, prod-, mainbranch, main-branch).
  # Im Zweifel gilt: lieber ein Treffer zu viel (= „nein“) als einer zu wenig.
  module ShadowRule
    VERSION = "SHADOW_RULE_V1"

    COMPOUND = %w[
      deploy release einspiel eingespiel produktion production firewall docker secret passwort passwör password rotation rotate rotier
      lösch loesch delete unumkehr irrevers nicht\ umkehrbar not\ reversible force budget kost modell model kund customer
      versand versend shipping vertrag verträg contract priorit prio architektur architecture zuständig zustaendig ownership
      startfreigabe start\ approval prüfer pruefer reviewer approver token
      host port dns ssh sshd geld money mail email cost scope gate
      produktiv productive prod- mainbranch main-branch localhost webhost migrat database datenbank credential
    ].freeze
    # Eintrag mit Muster statt Stamm.
    REGEX = { "api[- ]?key" => /(?<![[:alpha:]])api[- ]?key/i }.freeze
    WORD = %w[main prod].freeze
    ENDINGS = "s|e|en|n|er|es|ern|ing|ed"

    RESERVED_WORDS = (COMPOUND + REGEX.keys + WORD).freeze

    Verdict = Struct.new(:would_auto, :reason, keyword_init: true)

    PATTERNS = (
      COMPOUND.map { |stem| [stem, /(?<![[:alpha:]])#{Regexp.escape(stem).gsub("\\ ") { "\\s+" }}/i] } +
      REGEX.to_a +
      WORD.map { |stem| [stem, /(?<![[:alpha:]])#{Regexp.escape(stem)}(?:#{ENDINGS})?(?![[:alpha:]])/i] }
    ).freeze

    module_function

    # Erstes Wort der Vorbehaltsliste in den Texten oder nil.
    def reserved_word(*texts)
      haystack = texts.flatten.compact.map(&:to_s).join("\n")
      PATTERNS.each { |stem, pattern| return stem if haystack.match?(pattern) }
      nil
    end

    # source: "ask" | "chat"; texts: Frage, Optionen und Kontext (beliebig verschachtelt).
    def call(source:, kind:, reversible:, recommended:, texts: [])
      reason = first_no(source:, kind:, reversible:, recommended:, texts:)
      Verdict.new(would_auto: reason.nil?, reason: "#{VERSION}: #{reason ? "nein, #{reason}" : 'ja'}")
    end

    def first_no(source:, kind:, reversible:, recommended:, texts:)
      return "Chat-Frage (in V1 nie)" unless source.to_s == "ask"
      return "Art ist nicht entscheidung" unless kind.to_s == "entscheidung"
      return "nicht als umkehrbar markiert" unless reversible == true
      return "keine Empfehlung" if recommended.to_s.strip.empty?

      word = reserved_word(texts)
      word ? "Vorbehaltswort „#{word}“" : nil
    end
  end
end
