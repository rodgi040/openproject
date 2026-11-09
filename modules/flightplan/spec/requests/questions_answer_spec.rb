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

  it "answers from the chat and returns the remaining list" do
    post "/flightplan/questions/#{question.id}/answer",
         params: { text: "aus dem Chat" },
         headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:ok), response.body
    payload = JSON.parse(response.body)
    expect(payload["ok"]).to be(true)
    expect(payload["items"]).to eq([])
    expect(question.reload.answer).to eq("aus dem Chat")
    # OP#1710: Bestätigung mit Antwort, Ticket und Status
    expect(payload["answer"]).to include("id" => question.id, "work_package_id" => work_package.id, "text" => "aus dem Chat",
                                         "status" => work_package.reload.status.name)
    expect(payload["answer"]["message"]).to eq("Beantwortet: aus dem Chat – ##{work_package.id}, Status jetzt #{work_package.status.name}")
  end

  it "confirms a chosen option with the status in the flash message without JSON" do
    question.update!(options: %w[Ja Nein])

    post "/flightplan/questions/#{question.id}/answer", params: { option: "Ja" }

    expect(response).to have_http_status(:redirect), response.body
    expect(flash[:notice]).to eq("Beantwortet: Ja – ##{work_package.id}, Status jetzt #{work_package.reload.status.name}")
  end

  it "shortens long free text in the confirmation" do
    post "/flightplan/questions/#{question.id}/answer", params: { text: "x" * 200 },
                                                         headers: { "ACCEPT" => "application/json" }

    expect(JSON.parse(response.body)["answer"]["message"]).to include("#{'x' * 57}...")
  end

  it "answers 409 as JSON when the question is already answered" do
    post "/flightplan/questions/#{question.id}/answer", params: { text: "eins" }, headers: { "ACCEPT" => "application/json" }
    post "/flightplan/questions/#{question.id}/answer", params: { text: "zwei" }, headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body)).to eq("ok" => false, "error" => "Die Frage ist bereits beantwortet")
  end

  it "answers 422 as JSON when neither option nor text is given" do
    post "/flightplan/questions/#{question.id}/answer", headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["ok"]).to be(false)
  end

  context "without the Mensch role" do
    current_user { author }

    it "answers 403 as JSON" do
      post "/flightplan/questions/#{question.id}/answer", params: { text: "nein" }, headers: { "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["ok"]).to be(false)
      expect(question.reload).to be_open
    end
  end
end
