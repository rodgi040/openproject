# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

# OP#1671: Die Startseite (/) zeigt angemeldeten Nutzern das ADA-Dashboard mit fester Chat-Spalte rechts,
# keine der Upstream-Homescreen-Blöcke. Administration und Kontoeinstellungen bleiben über das Menü erreichbar.
RSpec.describe "Flightplan Startseite", :skip_csrf,
               type: :rails_request,
               with_settings: { welcome_on_homescreen: true, welcome_text: "Willkommen-Probe 1671" } do
  # Turbo-Frame-IDs der Upstream-Blöcke (Grids::WidgetComponent.wrapper_key), im Base-Stand gemessen, und ihre Titel.
  let(:upstream_keys) do
    %w[welcome my-account new-features community administration upsell].map { |name| "homescreen-blocks-#{name}" } +
      %w[grids-widgets-favorite-projects grids-widgets-news meetings-widgets-meetings]
  end
  let(:upstream_titles) do
    ["Willkommen-Probe 1671", "Favorisierte Projekte", "Meine Besprechungen", "Neue Funktionen",
     "Kontoeinstellungen", "Neuigkeiten", "Administration", "OpenProject Community"]
  end

  let(:admin) { create(:admin, language: "de") }
  let(:member) { create(:user, language: "de") }

  before do
    allow(OpenProject::Configuration).to receive(:show_community_links?).and_return(true)
  end

  def content
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("#content-body")).to be_present, response.body
    page.at_css("#content-body")
  end

  def expect_no_upstream_blocks
    upstream_keys.each { |key| expect(response.body).not_to include(key) }
    text = content.text
    upstream_titles.each { |title| expect(text).not_to include(title) }
  end

  describe "as admin" do
    current_user { admin }

    it "shows the ADA dashboard on / and none of the upstream homescreen blocks" do
      get "/"
      expect(response).to have_http_status(:ok)
      expect(content.at_css("#fp-home .fp-home-main #fp-dashboard")).to be_present
      expect(content.text).to include("ADA Dashboard")
      expect_no_upstream_blocks
    end

    it "keeps Administration and account settings reachable through the menu" do
      get "/"
      page = Nokogiri::HTML(response.body)
      outside = page.css("a[href$='/admin'], a[href$='/my/account']").reject { |link| link.ancestors("#content-body").any? }
      expect(outside.map { |link| URI(link["href"]).path }).to include("/admin", "/my/account")
    end

    it "puts the chat column on the right, loaded lazily with an offline notice and reload" do
      get "/"
      chat = content.at_css("#fp-home > .fp-home-chat")
      expect(chat).to be_present
      expect(content.at_css("#fp-home > .fp-home-main + .fp-home-chat")).to be_present
      frame = chat.at_css("iframe[data-fp-home-frame]")
      expect(frame).to be_present
      expect(frame["data-src"]).to eq("http://localhost:8092/chat/")
      expect(frame["src"]).to be_nil
      expect(chat.at_css("[data-fp-chat-offline][hidden]")).to be_present
      expect(chat.at_css("[data-fp-chat-reload]")).to be_present
      expect(chat.at_css("[data-fp-chat-admin-only]")).to be_nil
    end

    it "keeps #fp-home a direct child of #content-body, which the height rule selects" do
      get "/"
      expect(Nokogiri::HTML(response.body).at_css("#content-body > #fp-home")).to be_present
    end

    it "allows the reachability fetch of the chat on / (connect-src)" do
      get "/"
      header = response.headers["Content-Security-Policy"].to_s
      expect(header[/connect-src[^;]*/].to_s).to include("http://localhost:8092")
      expect(header[/frame-src[^;]*/].to_s).to include("http://localhost:8092")
    end

    it "sends /flightplan/dashboard to the main page (OP#1721)" do
      get "/flightplan/dashboard"
      expect(response).to redirect_to("/")
      get "/"
      expect(content.at_css("#fp-home > .fp-home-main #fp-dashboard")).to be_present
      expect(content.at_css("#fp-home > .fp-home-chat iframe[data-fp-home-frame]")).to be_present
    end

    it "runs after the upstream jump_to_module, so /?jump=… keeps working" do
      filters = HomescreenController._process_action_callbacks.select { |callback| callback.kind == :before }.map(&:filter)
      expect(filters).to include(:jump_to_module, :flightplan_startseite)
      expect(filters.index(:jump_to_module)).to be < filters.index(:flightplan_startseite)
    end

    it "serves a stylesheet that keeps the home chat inside the visible area at every zoom level" do
      get "/flightplan/assets/flightplan.css"
      expect(response).to have_http_status(:ok)
      css = response.body
      expect(css).to include("#content-body:has(> #fp-home)",
                             "--fp-home-fit: calc(100dvh - var(--header-height, 55px) - 1.5rem)")
      home_rules = css.scan(/\.fp-home(?:-main|-chat|-frame)?\s*\{[^}]*\}/).join("\n")
      expect(home_rules).to include("grid-template-rows: minmax(0, 1fr)", "height: var(--fp-home-fit)")
      expect(home_rules).not_to match(/min-height:\s*(32rem|calc\(100vh)/)
    end

    # OP#1711: Ticketleiste im Chat.
    describe "ticket bar of the chat" do
      let(:project) { create(:project, public: false, members: { admin => create(:project_role, permissions: %i[view_work_packages]) }) }
      let(:bar) { content.at_css(".fp-home-chat [data-fp-chat-tickets]") }

      def ensure_status(name)
        Status.find_by(name:) || create(:status, name:)
      end

      it "shows a running ticket with a link and data attributes to /chat/embed/<id>, and escapes the title" do
        running = create(:work_package, project:, status: ensure_status("In Arbeit"), subject: "<img src=x onerror=alert(1)> Probe")
        done = create(:work_package, project:, status: ensure_status("Geplant"), subject: "Nicht laufend")
        get "/"
        link = bar.at_css("a[data-fp-chat-ticket='#{running.id}']")
        expect(link).to be_present
        expect(link["href"]).to eq("http://localhost:8092/chat/embed/#{running.id}")
        expect(link.at_css(".fp-chat-ticket-title").text).to include("<img src=x onerror=alert(1)> Probe")
        expect(bar.at_css("img")).to be_nil
        expect(response.body).not_to include("<img src=x onerror")
        expect(bar.at_css("a[data-fp-chat-ticket='#{done.id}']")).to be_nil
        expect(bar.at_css("[data-fp-chat-new]")).to be_present
        expect(bar.at_css("[data-fp-chat-tickets-empty]")).to be_nil
        expect(bar.at_css("[data-fp-chat-tickets-count]").text).to include("Laufend (1)")
        expect(bar.css("[aria-current]").size).to eq(1)
      end

      it "orders In Arbeit before Wartet auf Mensch and Review, and counts every running ticket" do
        review = create(:work_package, project:, status: ensure_status("Review"), subject: "R")
        waiting = create(:work_package, project:, status: ensure_status("Wartet auf Mensch"), subject: "W")
        running = create(:work_package, project:, status: ensure_status("In Arbeit"), subject: "A")
        stub_const("Flightplan::ChatTickets::LIMIT", 2)
        get "/"
        ids = bar.css("[data-fp-chat-ticket-list] [data-fp-chat-ticket]").map { |node| node["data-fp-chat-ticket"].to_i }
        expect(ids).to eq([running.id, waiting.id])
        expect(ids).not_to include(review.id)
        expect(bar.at_css("[data-fp-chat-tickets-count]").text).to include("Laufend: 2 von 3")
      end

      it "shows an empty state instead of an empty bar without running tickets" do
        get "/"
        expect(bar.at_css("[data-fp-chat-tickets-empty]").text).to include("Keine laufenden Tickets")
        expect(bar.at_css("[data-fp-chat-ticket]")).to be_nil
      end
    end
  end

  describe "as a user without admin rights" do
    current_user { member }

    it "shows a notice instead of the dashboard and the chat, and no upstream blocks" do
      get "/"
      expect(response).to have_http_status(:ok)
      expect(content.at_css("#fp-home")).to be_present
      expect(content.at_css("#fp-dashboard")).to be_nil
      expect(content.at_css("[data-fp-dashboard-admin-only]")).to be_present
      expect(content.at_css(".fp-home-chat [data-fp-chat-admin-only]")).to be_present
      expect(content.text).to include("Chat (T3 Code) steht nur Administratoren zur Verfügung")
      expect(response.body).not_to include("<iframe", "localhost:8092/chat/")
      expect(response.body).not_to include("data-fp-chat-tickets")
      expect_no_upstream_blocks
    end

    it "keeps the old dashboard address admin-only" do
      get "/flightplan/dashboard"
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "anonymous", with_settings: { login_required: true } do
    it "sends the visitor to the login, as upstream does" do
      get "/"
      expect(response).to redirect_to(%r{/login})
    end
  end
end
