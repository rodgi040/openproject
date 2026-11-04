# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

RSpec.describe "Flightplan workplace", :skip_csrf,
               type: :rails_request,
               with_settings: { journal_aggregation_time_minutes: 0 } do
  def ensure_status(name, closed: false)
    status = Status.find_by(name:) || create(:status, name:, is_closed: closed)
    status.update!(is_closed: closed) if status.is_closed? != closed
    status
  end

  def change_status(work_package, status)
    result = WorkPackages::UpdateService.new(user: member, model: work_package).call(status:)
    expect(result).to be_success, result.errors.full_messages.inspect
    work_package.reload
  end

  let(:role) do
    create(:project_role, permissions: %i[
      view_work_packages edit_work_packages add_work_package_notes change_work_package_status
    ])
  end
  let(:project) { create(:project, name: "Workplace Probe", public: false) }
  let(:hidden) { create(:project, name: "Workplace Secret", public: false) }
  let(:member) { create(:user, language: "de", member_with_roles: { project => role }) }
  let!(:neu) { ensure_status("Neu") }
  let!(:geplant) { ensure_status("Geplant") }
  let!(:in_arbeit) { ensure_status("In Arbeit") }
  let!(:review) { ensure_status("Review") }
  let!(:fertig) { ensure_status("Fertig", closed: true) }
  let!(:labels) do
    create(:multi_list_wp_custom_field, name: "Labels", possible_values: %w[bug], projects: [project])
  end
  let!(:parent_wp) { create(:work_package, project:, author: member, status: neu, subject: "W11 Eltern") }
  let!(:package) do
    create(:work_package, project:, author: member, status: neu, subject: "W11 Arbeitsplatz",
                          description: "Branch: feature/w11-probe\n" + ("Wort " * 80))
  end
  let!(:open_child) { create(:work_package, project:, author: member, status: in_arbeit, subject: "W11 Kind offen") }
  let!(:done_child) { create(:work_package, project:, author: member, status: fertig, subject: "W11 Kind fertig") }
  let!(:secret) { create(:work_package, project: hidden, author: member, status: neu, subject: "W11 Geheim") }

  current_user { member }

  before do
    package.update_columns(parent_id: parent_wp.id)
    open_child.update_columns(parent_id: package.id)
    done_child.update_columns(parent_id: package.id)
    [neu, geplant, in_arbeit, review, fertig].permutation(2).each do |from, to|
      create(:workflow, type: package.type, role:, old_status: from, new_status: to)
    end
    bug = labels.custom_options.find_by!(value: "bug")
    CustomValue.create!(customized: package, custom_field: labels, value: bug.id.to_s)
    change_status(package, geplant)
    change_status(package, in_arbeit)
    change_status(package, review)
    note = AddWorkPackageNoteService.new(user: member, work_package: package).call("claim w11-session")
    expect(note).to be_success
    pr = AddWorkPackageNoteService.new(user: member, work_package: package.reload)
      .call("PR: https://github.com/rodgi040/example/pull/11")
    expect(pr).to be_success
    package.reload
  end

  it "renders the workplace with timeline, tree, progress and agent runs" do
    get "/flightplan/work_packages/#{package.id}"

    expect(response).to have_http_status(:ok), response.body
    expect(response.body).to include("W11 Arbeitsplatz")
    expect(response.body).to include('data-fp-status="Review"')
    expect(response.body).to include("bug")
    expect(response.body).to include("feature/w11-probe")
    expect(response.body).to include("https://github.com/rodgi040/example/pull/11")
    expect(response.body).to include("<details")
    timeline = response.body[/data-fp-timeline>(.*?)<\/ol>/m, 1]
    expect(timeline).to include('data-status="Neu"', 'data-status="Geplant"', 'data-status="In Arbeit"', 'data-status="Review"')
    expect(response.body).to include('data-role="parent"', "W11 Eltern")
    expect(response.body).to include('data-role="child"', "W11 Kind offen", "W11 Kind fertig")
    expect(response.body).to include('data-fp-progress', 'data-done="1"', 'data-total="2"')
    expect(response.body).to include('data-kind="start"', 'data-kind="claim"', "w11-session")
    expect(response.body).not_to include("'*'")
    header = response.headers["Content-Security-Policy"].to_s
    expect(header).to include("frame-src")
    expect(header).to include("http://localhost:8092")
    expect(header[/connect-src[^;]*/]).to include("http://localhost:8092")
  end

  it "adds connect-src for the chat only on Flightplan controllers, not on other pages" do
    get "/projects"
    expect(response).to have_http_status(:ok)
    header = response.headers["Content-Security-Policy"].to_s
    expect(header[/connect-src[^;]*/].to_s).not_to include("http://localhost:8092")
  end

  describe "chat" do
    it "shows non-admins a notice instead of the iframe" do
      get "/flightplan/work_packages/#{package.id}"
      expect(response.body).to include("data-fp-chat-admin-only", "Chat nur für Admins.")
      expect(response.body).not_to include("<iframe", "/chat/embed/")
    end

    context "as admin" do
      let(:member) do
        create(:admin, language: "de", member_with_roles: { project => role })
      end

      it "renders the frame lazily with an unreachable notice and reload button, no inline script" do
        get "/flightplan/work_packages/#{package.id}"
        expect(response.body).to include(%(data-src="http://localhost:8092/chat/embed/#{package.id}"))
        expect(response.body).to include("data-fp-chat-offline", "Chat nicht erreichbar", "data-fp-chat-reload", "Neu laden")
        expect(response.body[/<iframe[^>]*>/]).not_to include(" src=")
        expect(response.body).not_to include("data-fp-chat-admin-only")
        expect(response.body[/<div class="fp-chat-offline"[^>]*>/]).to include("hidden")
      end
    end
  end

  describe "Langfuse link" do
    around do |example|
      saved = ENV.values_at("FLIGHTPLAN_LANGFUSE_URL", "FLIGHTPLAN_LANGFUSE_PROJECT")
      example.run
    ensure
      saved.zip(%w[FLIGHTPLAN_LANGFUSE_URL FLIGHTPLAN_LANGFUSE_PROJECT]).each { |v, k| v ? ENV[k] = v : ENV.delete(k) }
    end

    before do
      ENV.delete("FLIGHTPLAN_LANGFUSE_URL")
      ENV.delete("FLIGHTPLAN_LANGFUSE_PROJECT")
    end

    it "shows no link without configuration" do
      get "/flightplan/work_packages/#{package.id}"
      expect(response.body).not_to include("data-fp-langfuse", "3200")
    end

    it "links the trace search for op-<id> and the branch, with the tunnel hint" do
      ENV["FLIGHTPLAN_LANGFUSE_URL"] = "http://localhost:3200/"
      ENV["FLIGHTPLAN_LANGFUSE_PROJECT"] = "factory"
      get "/flightplan/work_packages/#{package.id}"
      body = response.body
      expect(body).to include("data-fp-langfuse",
                              %(href="http://localhost:3200/project/factory/traces?search=op-#{package.id}"),
                              "search=feature%2Fw11-probe", "SSH-Tunnel", "localhost:3200")
      expect(body).to include('rel="noopener noreferrer"')
    end

    it "refuses a URL that is not http(s) or carries credentials" do
      ["javascript:alert(1)", "http://user:pw@localhost:3200"].each do |bad|
        ENV["FLIGHTPLAN_LANGFUSE_URL"] = bad
        get "/flightplan/work_packages/#{package.id}"
        expect(response.body).not_to include("data-fp-langfuse")
      end
    end
  end

  describe "timeline per change" do
    it "shows the previous status of every change" do
      get "/flightplan/work_packages/#{package.id}"
      timeline = response.body[/data-fp-timeline>(.*?)<\/ol>/m, 1]
      expect(timeline).to include("Neu →", "Geplant →", "In Arbeit →")
      expect(timeline.scan("<li ").size).to eq(4)
    end

    it "documents the limit: changes merged by the journal aggregation appear as one net change",
       with_settings: { journal_aggregation_time_minutes: 5 } do
      quick = create(:work_package, project:, author: member, status: neu, subject: "W11 Schnell")
      [geplant, in_arbeit].permutation(2).each do |from, to|
        create(:workflow, type: quick.type, role:, old_status: from, new_status: to)
      end
      create(:workflow, type: quick.type, role:, old_status: neu, new_status: geplant)
      create(:workflow, type: quick.type, role:, old_status: neu, new_status: in_arbeit)
      change_status(quick, geplant)
      change_status(quick, in_arbeit)
      get "/flightplan/work_packages/#{quick.id}"
      timeline = response.body[/data-fp-timeline>(.*?)<\/ol>/m, 1]
      expect(timeline).to include('data-status="In Arbeit"')
      expect(timeline).not_to include('data-status="Geplant"')
    end
  end

  describe "timeline cost" do
    def count_queries
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        get "/flightplan/work_packages/#{package.id}"
      end
      expect(response).to have_http_status(:ok)
      queries.size
    end

    it "needs a constant number of queries, however many journals the package has" do
      get "/flightplan/work_packages/#{package.id}" # warm caches
      few = count_queries
      25.times do
        change_status(package, geplant)
        change_status(package, in_arbeit)
      end
      expect(package.journals.count).to be > 50
      many = count_queries
      expect(many).to be <= few + 2
    end

    it "shows only the last 100 journals and says the list is cut" do
      get "/flightplan/work_packages/#{package.id}"
      expect(response.body).not_to include("data-fp-timeline-cut")
      52.times do
        change_status(package, geplant)
        change_status(package, in_arbeit)
      end
      get "/flightplan/work_packages/#{package.id}"
      timeline = response.body[/data-fp-timeline>(.*?)<\/ol>/m, 1]
      expect(timeline.scan("<li ").size).to eq(100)
      expect(response.body).to include("data-fp-timeline-cut", "Gekürzt")
    end
  end

  it "hides a package the user cannot see" do
    get "/flightplan/work_packages/#{secret.id}"

    expect(response).to have_http_status(:not_found)
  end
end
