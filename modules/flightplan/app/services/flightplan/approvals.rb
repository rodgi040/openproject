# frozen_string_literal: true

module Flightplan
  # Startfreigabe durch einen Menschen (S8). Setzt nur den Status auf "Startfreigabe", als der angemeldete
  # Mensch, damit das Journal ihn als Autor zeigt und das Start-Tor (op_poller, ada-dispatch) die Freigabe
  # anerkennt. Kein Start-Label, kein Agent-Start. Der Statuswechsel geht durch WorkPackages::UpdateService,
  # also durch Vertrag und Workflow der Rolle; es gibt keine Umgehung.
  class Approvals
    TARGET_STATUS = "Startfreigabe"
    MAX_ENTRIES = 100
    # Spiegel von openproject/config/configure.rb (AGENT_USERS, DISPATCHER_USER, SYNC_USER und die Gruppen
    # "Agenten*"). Diese Konten sind nie Menschen und dürfen nie freigeben.
    AGENT_LOGINS = %w[claude codex cursor opencode hermes engine gandalf agentscope dispatcher github-sync].freeze
    AGENT_GROUPS = ["Agenten", "Agenten Coding", "Agenten ADA"].freeze
    # Allowlist (fail-closed): nur diese Logins dürfen freigeben, zusätzlich zur Sperrliste und zum Admin-Recht.
    # Komma-Liste in der Umgebung (kein Secret, steht in der Compose-Datei). Nicht gesetzt: Standard "admin".
    # Gesetzt, aber leer: niemand gibt frei.
    HUMAN_LOGINS_ENV = "FLIGHTPLAN_HUMAN_LOGINS"
    DEFAULT_HUMAN_LOGINS = "admin"

    Result = Struct.new(:ok, :rejected, keyword_init: true) do
      def ok_count = ok.size
      def rejected_count = rejected.size
    end

    # Rejection = [id_or_nil, reason_key]
    def self.agent_user?(user)
      return true if AGENT_LOGINS.include?(user.login.to_s)

      GroupUser.where(user_id: user.id, group_id: Group.where(lastname: AGENT_GROUPS).select(:id)).exists?
    end

    def self.human_logins
      ENV.fetch(HUMAN_LOGINS_ENV, DEFAULT_HUMAN_LOGINS).to_s.split(",").map(&:strip).compact_blank.uniq
    end

    def self.allowlist_empty?
      human_logins.empty?
    end

    # Als Mensch markiert: Login steht in der Allowlist und ist kein Agent-Konto.
    def self.human?(user)
      user.logged? && human_logins.include?(user.login.to_s) && !agent_user?(user)
    end

    # :ok, :disabled (Allowlist leer) oder :not_human (Konto nicht in der Allowlist). Für den Hinweis der Seite.
    def self.availability(user)
      return :disabled if allowlist_empty?

      human?(user) ? :ok : :not_human
    end

    # entries: Array von { id: "123", lock_version: "4" }
    def self.call(user:, entries:)
      new(user, entries).call
    end

    def initialize(user, entries)
      @user = user
      @entries = entries
    end

    def call
      result = Result.new(ok: [], rejected: [])
      status = Status.find_by(name: TARGET_STATUS)
      @entries.first(MAX_ENTRIES).each do |entry|
        outcome = safe_approve(entry, status)
        outcome == :ok ? result.ok << entry[:id].to_i : result.rejected << [entry[:id].to_i, outcome]
      end
      result.rejected.unshift([nil, :too_many]) if @entries.size > MAX_ENTRIES
      result
    end

    private

    # Eine Ausnahme bei einem Eintrag bricht die Sammelfreigabe nicht ab. Der Grund nennt nur die
    # Ausnahmeklasse, nie die Meldung (keine Titel, keine Interna).
    def safe_approve(entry, status)
      approve(entry, status)
    rescue StandardError => e
      Rails.logger.error("[flightplan] approval ##{entry[:id].to_s[0, 20]} failed: #{e.class}: #{e.message}")
      "Fehler (#{e.class.name})"
    end

    def approve(entry, status)
      return :no_status unless status

      id = Integer(entry[:id].to_s, 10, exception: false)
      return :invalid_id unless id&.positive?

      lock = Integer(entry[:lock_version].to_s, 10, exception: false)
      return :lock_missing unless lock

      work_package = WorkPackage.visible(@user).find_by(id:)
      return :not_found unless work_package
      return :wrong_status unless Dashboard::APPROVABLE_STATUSES.include?(work_package.status&.name)
      return :wrong_master unless master(work_package) == "op"
      return :conflict unless work_package.lock_version == lock

      update(work_package, status)
    end

    def update(work_package, status)
      result = nil
      Journal::NotificationConfiguration.with(false) do
        result = WorkPackages::UpdateService.new(user: @user, model: work_package).call(status:)
      end
      return result.errors.full_messages.to_sentence.presence || :conflict unless result.success?

      :ok
    rescue ActiveRecord::StaleObjectError
      :conflict
    end

    def master(work_package)
      field = WorkPackageCustomField.find_by(name: Dashboard::MASTER_FIELD)
      return nil unless field

      value = CustomValue.where(customized: work_package, custom_field: field).pick(:value)
      field.custom_options.find_by(id: value)&.value
    end
  end
end
