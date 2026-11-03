# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

RSpec.describe "Flightplan question answer", :skip_csrf, type: :rails_request do
  let(:project) { create(:project) }
  let(:role) { create(:project_role, permissions: %i[view_work_packages add_work_package_comments]) }
  let(:author) { create(:user, member_with_roles: { project => role }) }
  let(:admin) { create(:admin, member_with_roles: { project => role }) }
  let(:work_package) { create(:work_package, project:, author:) }
  let!(:question) do
    Flightplan::Question.create!(
      work_package:,
      author:,
      question: "Doppelt?",
      status: "open"
    )
  end

  current_user { admin }

  it "reports an already answered question instead of missing" do
    post "/flightplan/questions/#{question.id}/answer", params: { text: "eins" }

    expect(response).to have_http_status(:redirect), response.body
    expect(question.reload.answer).to eq("eins")
    expect(question).not_to be_open

    post "/flightplan/questions/#{question.id}/answer", params: { text: "zwei" }

    expect(response).to have_http_status(:redirect), response.body
    expect(flash[:alert]).to eq("Die Frage ist bereits beantwortet")
    expect(question.reload.answer).to eq("eins")
  end
end
