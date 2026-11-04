# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"
require "base64"

# Startfreigabe-Knopf und Sammelfreigabe (S8). Anmeldung über die echte Session (POST /login), CSRF-Schutz
# ist während der Aufrufe eingeschaltet. Nur Admin, nur Session, nie API-Token.
RSpec.describe "Flightplan approvals", type: :rails_request do
  PASSWORD = "adminADMIN!1"

  def ensure_status(name, closed: false)
    Status.find_by(name:) || create(:status, name:, is_closed: closed)
  end

  def login(user)
    state = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    post "/login", params: { username: user.login, password: PASSWORD }
    ActionController::Base.allow_forgery_protection = state
    # Authentifizierungs-Stufen (2FA-Anfrage ohne Gerät) laufen über Weiterleitungen.
    4.times { follow_redirect! if response.redirect? && response.location.include?("two_factor") }
    expect(response).to have_http_status(:redirect), "#{response.status} #{response.body[0, 600]}"
  end

  def token_from(page)
    page[/name="authenticity_token" value="([^"]+)"/, 1] || page[/name="csrf-token" content="([^"]+)"/, 1]
  end

  # Holt Seite und Token wie ein Browser, dann ein POST mit Token.
  def approve(params = nil, token: :fetch, headers: {}, **rest)
    params ||= rest
    if token == :fetch
      get "/flightplan/dashboard"
      token = token_from(response.body)
    end
    post "/flightplan/approvals", params: params.merge(authenticity_token: token), headers:
  end

  # Die Testdaten legen "Master" ohne Journal an; dieser Eintrag kommt nur durch den Aufbau ins Journal.
  def status_only?(journal)
    journal.details.keys.reject { |key| key.start_with?("custom_fields_") } == ["status_id"]
  end

  def master(work_package, value)
    option = master_field.custom_options.find_by!(value:)
    CustomValue.create!(customized: work_package, custom_field: master_field, value: option.id.to_s)
  end

  let(:role) do
    create(:project_role, permissions: %i[view_work_packages edit_work_packages change_work_package_status])
  end
  let(:project) { create(:project, name: "Freigabe Projekt", public: false) }
  let!(:master_field) do
    create(:wp_custom_field, :list, name: "Master", possible_values: %w[github op], multi_value: false, is_for_all: true)
  end
  let!(:geplant) { ensure_status("Geplant") }
  let!(:waiting) { ensure_status("Wartet auf Mensch") }
  let!(:neu) { ensure_status("Neu") }
  let!(:startfreigabe) { ensure_status("Startfreigabe") }
  let(:admin) do
    create(:admin, login: "mensch-admin", password: PASSWORD, password_confirmation: PASSWORD, language: "de",
                   member_with_roles: { project => role })
  end
  let!(:op_wp) { create(:work_package, project:, author: admin, status: waiting, subject: "Op Eins") }
  let!(:op_geplant) { create(:work_package, project:, author: admin, status: geplant, subject: "Op Geplant") }
  let!(:gh_wp) { create(:work_package, project:, author: admin, status: waiting, subject: "Github Zwei") }
  let!(:neu_wp) { create(:work_package, project:, author: admin, status: neu, subject: "Neu Drei") }

  around do |example|
    saved = ENV.fetch("FLIGHTPLAN_HUMAN_LOGINS", nil)
    ENV["FLIGHTPLAN_HUMAN_LOGINS"] = "mensch-admin"
    example.run
  ensure
    saved ? ENV["FLIGHTPLAN_HUMAN_LOGINS"] = saved : ENV.delete("FLIGHTPLAN_HUMAN_LOGINS")
  end

  before do
    Rails.cache.clear
    [op_wp, op_geplant, neu_wp].each { |wp| master(wp, "op") }
    master(gh_wp, "github")
    create(:workflow, role:, type: op_wp.type, old_status: waiting, new_status: startfreigabe)
    # Geplant -> Startfreigabe ist absichtlich nicht im Workflow
    @forgery = ActionController::Base.allow_forgery_protection
  end

  def with_csrf
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = @forgery
  end

  describe "as admin with a session" do
    before { login(admin) }

    it "approves one package as the signed-in human, journal shows the admin as author" do
      with_csrf do
        approve(single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version })
      end
      expect(response).to redirect_to("/flightplan/dashboard")
      expect(flash[:notice]).to eq("1 freigegeben, 0 abgelehnt.")
      op_wp.reload
      expect(op_wp.status).to eq(startfreigabe)
      journal = op_wp.journals.order(:version).last
      expect(journal.user).to eq(admin)
      expect(status_only?(journal)).to be(true)
    end

    it "sets no label and starts no agent" do
      before_fields = CustomValue.where(customized: op_wp).pluck(:custom_field_id, :value).sort
      with_csrf { approve(single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version }) }
      expect(CustomValue.where(customized: op_wp).pluck(:custom_field_id, :value).sort).to eq(before_fields)
      expect(status_only?(op_wp.reload.journals.order(:version).last)).to be(true)
    end

    it "shows the button only for Geplant or Wartet auf Mensch with Master op" do
      get "/flightplan/dashboard"
      expect(response.body).to include("Starten freigeben")
      expect(response.body[/<tr data-wp="#{op_wp.id}">.*?<\/tr>/m]).to include("Starten freigeben", "fp-approve-check")
      expect(response.body[/<tr data-wp="#{gh_wp.id}">.*?<\/tr>/m]).not_to include("Starten freigeben")
      expect(response.body).to include("Ausgewählte zum Start freigeben")
    end

    it "reports a mixed bulk result with counts and reasons" do
      stale_lock = op_wp.lock_version - 1
      with_csrf do
        approve(ids: [op_wp.id.to_s, gh_wp.id.to_s, neu_wp.id.to_s, op_geplant.id.to_s, "999999", "<script>alert(1)</script>"],
                lock_versions: { op_wp.id => op_wp.lock_version, gh_wp.id => gh_wp.lock_version,
                                 neu_wp.id => neu_wp.lock_version, op_geplant.id => op_geplant.lock_version,
                                 "999999" => 1 })
      end
      expect(flash[:alert]).to start_with("1 freigegeben, 5 abgelehnt:")
      expect(flash[:alert]).to include("##{gh_wp.id} (Master ist nicht „op“)", "##{neu_wp.id} (Status ist nicht",
                                       "#999999 (nicht gefunden)", "Ungültige Nummer")
      expect(flash[:alert]).not_to include("<script>")
      expect(op_wp.reload.status).to eq(startfreigabe)
      expect(gh_wp.reload.status).to eq(waiting)
      expect(op_geplant.reload.status).to eq(geplant)
      expect(stale_lock).to be < op_wp.lock_version
    end

    it "rejects a lockVersion conflict without overwriting" do
      lock = op_wp.lock_version
      op_wp.update_columns(subject: "Zwischenzeitlich geändert", lock_version: lock + 1)
      with_csrf { approve(single: op_wp.id, lock_versions: { op_wp.id => lock }) }
      expect(flash[:alert]).to include("1 abgelehnt", "Konflikt")
      expect(op_wp.reload.status).to eq(waiting)
      expect(op_wp.subject).to eq("Zwischenzeitlich geändert")
    end

    it "rejects a missing lockVersion" do
      with_csrf { approve(single: op_wp.id) }
      expect(flash[:alert]).to include("lockVersion fehlt")
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "respects the workflow and reports the forbidden transition without bypass" do
      with_csrf { approve(single: op_geplant.id, lock_versions: { op_geplant.id => op_geplant.lock_version }) }
      expect(flash[:alert]).to include("1 abgelehnt", "##{op_geplant.id}")
      expect(op_geplant.reload.status).to eq(geplant)
    end

    it "keeps titles and flash escaped (XSS)" do
      op_wp.update_columns(subject: "<script>alert('x')</script>")
      get "/flightplan/dashboard"
      expect(response.body).not_to include("<script>alert('x')</script>")
      with_csrf { approve(ids: ["<img src=x onerror=alert(1)>"], lock_versions: {}) }
      follow_redirect!
      expect(response.body).not_to include("<img src=x")
      expect(response.body).not_to include("<script>alert('x')</script>")
    end

    it "says so when nothing is selected" do
      with_csrf { approve({}) }
      expect(flash[:alert]).to eq("Es wurde nichts ausgewählt.")
    end

    it "rejects a request without a CSRF token and changes nothing" do
      with_csrf do
        post "/flightplan/approvals", params: { single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version } }
      end
      expect(response).not_to redirect_to("/flightplan/dashboard")
      expect(op_wp.reload.status).to eq(waiting)
      with_csrf do
        post "/flightplan/approvals", params: { single: op_wp.id, authenticity_token: "falsch",
                                                lock_versions: { op_wp.id => op_wp.lock_version } }
      end
      expect(op_wp.reload.status).to eq(waiting)
    end
  end

  describe "bulk edge cases" do
    before { login(admin) }

    it "rejects more than 100 entries with too_many and still handles the first 100" do
      ids = (1..101).map(&:to_s)
      with_csrf { approve(ids:, lock_versions: ids.to_h { |id| [id, 1] }) }
      expect(flash[:alert]).to include("0 freigegeben", "zu viele Einträge")
    end

    it "keeps going after an exception in one entry and names the reason" do
      second = create(:work_package, project:, author: admin, status: waiting, subject: "Op Zwei")
      master(second, "op")
      original = WorkPackages::UpdateService.method(:new)
      allow(WorkPackages::UpdateService).to receive(:new) do |**args|
        raise "boom with <secret> title" if args[:model].id == op_wp.id

        original.call(**args)
      end
      with_csrf do
        approve(ids: [op_wp.id.to_s, second.id.to_s],
                lock_versions: { op_wp.id => op_wp.lock_version, second.id => second.lock_version })
      end
      expect(flash[:alert]).to start_with("1 freigegeben, 1 abgelehnt:")
      expect(flash[:alert]).to include("##{op_wp.id} (Fehler (RuntimeError))")
      expect(flash[:alert]).not_to include("secret")
      expect(second.reload.status).to eq(startfreigabe)
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "rejects an XHR with a wrong CSRF token and changes nothing" do
      with_csrf do
        post "/flightplan/approvals", xhr: true,
                                      params: { single: op_wp.id, authenticity_token: "falsch",
                                                lock_versions: { op_wp.id => op_wp.lock_version } }
      end
      expect(response).not_to have_http_status(:ok)
      expect(response).not_to be_redirect
      expect(op_wp.reload.status).to eq(waiting)
    end
  end

  describe "human allowlist" do
    it "answers 403 for an admin who is not listed, and the page explains why" do
      other = create(:admin, login: "anderer-admin", password: PASSWORD, password_confirmation: PASSWORD, language: "de",
                             member_with_roles: { project => role })
      login(other)
      get "/flightplan/dashboard"
      expect(response.body).to include("fp-approval-off", "steht nicht in FLIGHTPLAN_HUMAN_LOGINS")
      expect(response.body).not_to include("Starten freigeben")
      with_csrf { approve({ single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version } }) }
      expect(response).to have_http_status(:forbidden)
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "approves nobody when the list is empty (fail-closed) and shows a notice" do
      ENV["FLIGHTPLAN_HUMAN_LOGINS"] = " , "
      login(admin)
      get "/flightplan/dashboard"
      expect(response.body).to include("fp-approval-off", "Die Freigabe ist abgeschaltet")
      expect(response.body).not_to include("Starten freigeben")
      with_csrf { approve({ single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version } }) }
      expect(response).to have_http_status(:forbidden)
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "compares logins without regard to case or surrounding blanks" do
      ENV["FLIGHTPLAN_HUMAN_LOGINS"] = " #{admin.login.upcase} , x "
      expect(Flightplan::Approvals.human_logins).to eq([admin.login.downcase, "x"])
      expect(Flightplan::Approvals.human?(admin)).to be(true)
      upper = create(:admin, login: "MENSCH-X", password: PASSWORD, password_confirmation: PASSWORD,
                             member_with_roles: { project => role })
      ENV["FLIGHTPLAN_HUMAN_LOGINS"] = "mensch-x"
      expect(Flightplan::Approvals.human?(upper)).to be(true)
    end

    it "defaults to admin when the variable is unset, and keeps the agent blocklist on top" do
      ENV.delete("FLIGHTPLAN_HUMAN_LOGINS")
      expect(Flightplan::Approvals.human_logins).to eq(["admin"])
      ENV["FLIGHTPLAN_HUMAN_LOGINS"] = "claude, mensch-admin"
      agent = create(:admin, login: "claude", password: PASSWORD, password_confirmation: PASSWORD,
                             member_with_roles: { project => role })
      expect(Flightplan::Approvals.human?(agent)).to be(false)
      expect(Flightplan::Approvals.human?(admin)).to be(true)
    end
  end

  describe "rejected callers" do
    %w[Bearer Basic OAuth].each do |scheme|
      it "answers 403 for a #{scheme} Authorization header next to a valid session" do
        login(admin)
        with_csrf do
          approve({ single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version } },
                  headers: { "Authorization" => "#{scheme} Zm9vOmJhcg==" })
        end
        expect(response).to have_http_status(:forbidden)
        expect(op_wp.reload.status).to eq(waiting)
      end
    end

    it "answers 403 for an API key, even next to a valid session, and changes nothing" do
      login(admin)
      token = create(:api_token, user: admin)
      header = { "Authorization" => "Basic #{Base64.strict_encode64("apikey:#{token.plain_value}")}" }
      with_csrf do
        approve({ single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version } }, headers: header)
      end
      expect(response).to have_http_status(:forbidden)
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "answers 403 for an API key without any session" do
      token = create(:api_token, user: admin)
      header = { "Authorization" => "Basic #{Base64.strict_encode64("apikey:#{token.plain_value}")}" }
      ActionController::Base.allow_forgery_protection = false
      post "/flightplan/approvals", params: { single: op_wp.id }, headers: header
      ActionController::Base.allow_forgery_protection = @forgery
      expect(response).to have_http_status(:forbidden)
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "answers 403 for an agent account, even with admin rights" do
      agent = create(:admin, login: "claude", password: PASSWORD, password_confirmation: PASSWORD,
                             member_with_roles: { project => role })
      login(agent)
      with_csrf { approve({ single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version } }) }
      expect(response).to have_http_status(:forbidden)
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "answers 403 for a member of the Agenten group" do
      member = create(:admin, login: "bot-admin", password: PASSWORD, password_confirmation: PASSWORD,
                              member_with_roles: { project => role })
      create(:group, lastname: "Agenten", members: [member])
      login(member)
      ActionController::Base.allow_forgery_protection = false
      post "/flightplan/approvals", params: { single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version } }
      ActionController::Base.allow_forgery_protection = @forgery
      expect(response).to have_http_status(:forbidden), "#{response.status} #{response.location}"
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "answers 403 for a non-admin and changes nothing" do
      user = create(:user, login: "kein-admin", password: PASSWORD, password_confirmation: PASSWORD,
                           member_with_roles: { project => role })
      login(user)
      ActionController::Base.allow_forgery_protection = false
      post "/flightplan/approvals", params: { single: op_wp.id, lock_versions: { op_wp.id => op_wp.lock_version } }
      ActionController::Base.allow_forgery_protection = @forgery
      expect(response).to have_http_status(:forbidden)
      expect(op_wp.reload.status).to eq(waiting)
    end

    it "does not approve anonymously" do
      post "/flightplan/approvals", params: { single: op_wp.id }
      expect(response).not_to have_http_status(:ok)
      expect(op_wp.reload.status).to eq(waiting)
    end
  end
end
