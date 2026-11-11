# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"
require "base64"

# OP#1843: POST /flightplan/shadow (Chat-Frage vom Menschen beantwortet) und die Zusammenfassung. Echte Anmeldung über die
# Session, CSRF-Schutz eingeschaltet (wie chat_spec).
RSpec.describe "Flightplan shadow measurement", type: :rails_request do
  PASSWORD = "adminADMIN!1" unless defined?(PASSWORD)

  def login(user)
    state = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    post "/login", params: { username: user.login, password: PASSWORD }
    ActionController::Base.allow_forgery_protection = state
    4.times { follow_redirect! if response.redirect? && response.location.include?("two_factor") }
    expect(response).to have_http_status(:redirect), "#{response.status} #{response.body[0, 600]}"
  end

  def token_from(page)
    page[/name="csrf-token" content="([^"]+)"/, 1] || page[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def with_csrf
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = @forgery
  end

  def report(token: :fetch, headers: {}, **overrides)
    if token == :fetch
      get "/"
      token = token_from(response.body)
    end
    params = { ticket: work_package.id, request_id: "req-1", recommended: "Ja (Recommended)", chosen: "Nein",
               authenticity_token: token }.merge(overrides).compact
    post "/flightplan/shadow", params:, headers: { "ACCEPT" => "application/json" }.merge(headers)
  end

  let(:role) { create(:project_role, permissions: %i[view_work_packages add_work_package_comments]) }
  let(:human_role) { create(:project_role, name: "Mensch", permissions: %i[view_work_packages]) }
  let(:project) { create(:project, public: false) }
  let(:admin) do
    create(:admin, login: "mensch-admin", password: PASSWORD, password_confirmation: PASSWORD, language: "de",
                   member_with_roles: { project => role })
  end
  let(:work_package) { create(:work_package, project:, author: admin) }

  before do
    Rails.cache.clear
    @forgery = ActionController::Base.allow_forgery_protection
  end

  describe "POST /flightplan/shadow" do
    it "writes a chat row for a human admin and answers nothing" do
      login(admin)
      with_csrf { report }

      expect(response).to have_http_status(:ok), "#{response.status} #{response.body[0, 300]} #{response.headers.to_h.slice('WWW-Authenticate', 'Location')}"
      expect(JSON.parse(response.body)).to eq("ok" => true, "recorded" => true)
      expect(Flightplan::ShadowDecision.sole).to have_attributes(
        source: "chat", work_package_id: work_package.id, request_id: "req-1", recommended: "Ja (Recommended)", chosen: "Nein",
        matched: false, would_auto: false
      )
      expect(Flightplan::Question.count).to eq(0)
    end

    it "writes a row for a member with the role Mensch" do
      member = create(:user, login: "mensch-mitglied", password: PASSWORD, password_confirmation: PASSWORD,
                             member_with_roles: { project => human_role })
      login(member)
      with_csrf { report }

      expect(response).to have_http_status(:ok), response.body
      expect(Flightplan::ShadowDecision.count).to eq(1)
    end

    it "records the same request only once" do
      login(admin)
      with_csrf { report }
      with_csrf { report }

      expect(JSON.parse(response.body)["recorded"]).to be(false)
      expect(Flightplan::ShadowDecision.count).to eq(1)
    end

    it "marks matched when the human chose the recommended option" do
      login(admin)
      with_csrf { report(chosen: "Ja (Recommended)") }

      expect(Flightplan::ShadowDecision.sole.matched).to be(true)
    end

    it "rejects a request without a CSRF token and a wrong one, and writes nothing" do
      login(admin)
      with_csrf { post "/flightplan/shadow", params: { ticket: work_package.id, request_id: "r", recommended: "a", chosen: "b" },
                                             headers: { "ACCEPT" => "application/json" } }
      expect(response).not_to have_http_status(:ok)

      with_csrf { report(token: "falsch") }
      expect(response).not_to have_http_status(:ok)
      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "answers 403 for a member who is not a human (no role Mensch, no admin)" do
      other = create(:user, login: "nur-mitglied", password: PASSWORD, password_confirmation: PASSWORD,
                            member_with_roles: { project => role })
      login(other)
      with_csrf { report }

      expect(response).to have_http_status(:forbidden)
      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "answers 403 for an agent account with admin rights" do
      agent = create(:admin, login: "claude", password: PASSWORD, password_confirmation: PASSWORD,
                             member_with_roles: { project => role })
      login(agent)
      with_csrf { report }

      expect(response).to have_http_status(:forbidden)
      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "answers 403 for an API key and does not accept an anonymous caller" do
      token = create(:api_token, user: admin)
      header = { "Authorization" => "Basic #{Base64.strict_encode64("apikey:#{token.plain_value}")}" }
      ActionController::Base.allow_forgery_protection = false
      post "/flightplan/shadow", params: { ticket: work_package.id, request_id: "r", recommended: "a", chosen: "b" },
                                 headers: header.merge("ACCEPT" => "application/json")
      ActionController::Base.allow_forgery_protection = @forgery
      expect(response).to have_http_status(:forbidden)

      reset!
      with_csrf { report(token: "x") }
      expect(response.status).to be_in([401, 403])
      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "answers 404 for a ticket the user cannot see or that does not exist" do
      member = create(:user, login: "mensch-sicht", password: PASSWORD, password_confirmation: PASSWORD,
                             member_with_roles: { project => human_role })
      login(member)
      hidden = create(:work_package, project: create(:project, public: false))
      with_csrf { report(ticket: hidden.id) }
      expect(response).to have_http_status(:not_found)
      with_csrf { report(ticket: 0) }
      expect(response).to have_http_status(:not_found)
      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "answers 422 for missing, non-text and too long fields" do
      login(admin)
      with_csrf { report(request_id: nil) }
      expect(response).to have_http_status(:unprocessable_entity)
      with_csrf { report(recommended: "x" * 501) }
      expect(response).to have_http_status(:unprocessable_entity)
      with_csrf { report(chosen: "x" * 501) }
      expect(response).to have_http_status(:unprocessable_entity)
      with_csrf { report(request_id: "r" * 201) }
      expect(response).to have_http_status(:unprocessable_entity)
      with_csrf { report(chosen: { "a" => "b" }) }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Flightplan::ShadowDecision.count).to eq(0)
    end

    it "keeps markup as plain text" do
      login(admin)
      with_csrf { report(chosen: "<img src=x onerror=alert(1)>") }

      expect(Flightplan::ShadowDecision.sole.chosen).to eq("<img src=x onerror=alert(1)>")
    end
  end
end
