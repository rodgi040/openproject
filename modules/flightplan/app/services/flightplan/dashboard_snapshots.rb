# frozen_string_literal: true

module Flightplan
  # Lese-Schicht für die Host-Schnappschüsse (S0). Liest nur drei JSON-Dateien aus einem Verzeichnis,
  # das der Maintainer read-only in den Container einhängt (Standard /var/lib/ada-export):
  #
  #   status.json    Kopie von /var/lib/ada-health/status.json   (Vertrag openproject/betrieb/README.md)
  #   snapshot.json  Kopie von /var/lib/ada-status/snapshot.json (Anhang der Spec, openproject/status/README.md)
  #   dispatch.json  Ausgabe von `ada-dispatch status`           (openproject/orchestrator/README.md)
  #
  # Fehlt eine Datei oder ist sie unbrauchbar, ist die Quelle "nicht aktiv". Es gibt nie einen Fehler.
  # Gelesen werden nur reguläre Dateien (kein Symlink) bis 1 MiB. Es werden keine Pfade oder Inhalte geloggt.
  class DashboardSnapshots
    DEFAULT_DIR = "/var/lib/ada-export"
    DIR_ENV = "FP_EXPORT_DIR"
    MAX_BYTES = 1_048_576
    FUTURE_TOLERANCE = 60
    COLORS = %w[gruen gelb rot unbekannt].freeze

    # Gültigkeit in Sekunden: Schnappschuss 5 min (Spec), Gesundheitsstatus 15 min (Dead-Man-Grenze),
    # Dispatcher-Ausgabe 5 min (Herzschlag).
    SOURCES = {
      health: { file: "status.json", ttl: 900 },
      engine: { file: "snapshot.json", ttl: 300 },
      dispatch: { file: "dispatch.json", ttl: 300 }
    }.freeze

    # state: :ok (frisch), :stale (veraltet, Daten vorhanden), :inactive (nicht aktiv, keine Daten)
    Source = Struct.new(:key, :state, :data, :age, :reason, keyword_init: true) do
      def inactive?
        state == :inactive
      end

      def stale?
        state == :stale
      end

      def data?
        !inactive?
      end
    end

    def self.read_all(dir: nil, now: Time.current)
      new(dir:, now:).read_all
    end

    def initialize(dir: nil, now: Time.current)
      @dir = Pathname.new(dir.presence || ENV[DIR_ENV].presence || DEFAULT_DIR)
      @now = now
    end

    def read_all
      SOURCES.keys.index_with { |key| read(key) }
    end

    def read(key)
      spec = SOURCES.fetch(key)
      path = @dir.join(spec[:file])
      data, mtime = load_json(path)
      return inactive(key, data) unless data.is_a?(Hash)

      stamp = timestamp(key, data) || mtime
      # Ein Zeitstempel in der Zukunft (mehr als eine Minute Uhrenabweichung) ist unbrauchbar.
      return inactive(key, :future) if stamp && stamp > @now + FUTURE_TOLERANCE
      age = stamp ? [@now - stamp, 0].max : nil
      state = age.nil? || age > spec[:ttl] ? :stale : :ok
      Source.new(key:, state:, data:, age:, reason: nil)
    end

    # Erlaubte Ampelwerte; alles andere zählt als "unbekannt" (Inhalt ist nicht vertrauenswürdig).
    def self.color(value)
      COLORS.include?(value.to_s) ? value.to_s : "unbekannt"
    end

    private

    def inactive(key, reason)
      Source.new(key:, state: :inactive, data: nil, age: nil, reason: reason.is_a?(Symbol) ? reason : :invalid)
    end

    # Gibt [Hash, mtime] oder [Grund, nil] zurück.
    def load_json(path)
      stat = File.lstat(path)
      return [:not_file, nil] unless stat.file?
      return [:too_large, nil] if stat.size > MAX_BYTES

      [JSON.parse(File.read(path)), stat.mtime]
    rescue Errno::ENOENT, Errno::ENOTDIR
      [:missing, nil]
    rescue Errno::EACCES, Errno::EPERM
      [:unreadable, nil]
    rescue JSON::ParserError, EncodingError
      [:invalid, nil]
    rescue SystemCallError, IOError
      [:unreadable, nil]
    end

    def timestamp(key, data)
      case key
      when :health
        beat = data["heartbeat"]
        epoch = beat.is_a?(Hash) ? beat["epoch"] : nil
        Time.zone.at(epoch) if epoch.is_a?(Numeric)
      else
        raw = data["erzeugt_am"] || data["zeitpunkt"]
        Time.iso8601(raw.to_s).in_time_zone if raw.is_a?(String)
      end
    rescue ArgumentError, RangeError, FloatDomainError
      nil
    end
  end
end
