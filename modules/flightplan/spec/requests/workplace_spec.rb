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
  let(:member) { create(:user, member_with_roles: { project => role }) }
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
    expect(response.body).to include("/chat/embed/#{package.id}")
    expect(response.body).not_to include("'*'")
    header = response.headers["Content-Security-Policy"].to_s
    expect(header).to include("frame-src")
    expect(header).to include("http://localhost:8092")
  end

  it "hides a package the user cannot see" do
    get "/flightplan/work_packages/#{secret.id}"

    expect(response).to have_http_status(:not_found)
  end
end
