# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

# OP#1842/OP#1843: Rückfrage mit Struktur in „Braucht dich“ und im Rückfragen-Widget, Daten für die T3-Kopfleiste,
# Schatten-Zeile (nur Admins) und Locale-Schlüssel de/en.
RSpec.describe "Flightplan structured questions in the dashboard", :skip_csrf, type: :rails_request do
  let!(:task_type) { Type.find_by(name: "Aufgabe") || create(:type, name: "Aufgabe") }
  let!(:project) { create(:project, name: "Struktur Fabrik", identifier: "struktur-fabrik", public: false, types: [task_type]) }
  let(:role) { create(:project_role, permissions: %i[view_work_packages add_work_package_comments]) }
  let(:admin) { create(:admin, language: "de", member_with_roles: { project => role }) }
  let(:member) { create(:user, language: "de", member_with_roles: { project => role }) }
  let(:agent) { create(:user, member_with_roles: { project => role }) }
  let(:work_package) { create(:work_package, project:, type: task_type, subject: "Struktur Ticket") }

  def page
    Nokogiri::HTML(response.body)
  end

  def ask(attributes = {})
    Flightplan::Question.create!(
      { work_package:, author: agent, question: "Welche Variante?", options: %w[A B], status: "open" }.merge(attributes)
    )
  end

  describe "the inbox row" do
    current_user { admin }

    it "shows kind, recommendation, consequence and the Enter hint for a reversible recommended question" do
      question = ask(kind: "entscheidung", recommended_option: "B", reversible: true, consequence: "Danach neu bauen")
      get "/"

      row = page.at_css("#fp-inbox [data-fp-question='#{question.id}']")
      expect(row["data-fp-recommended"]).to eq("B")
      expect(row["data-fp-reversible"]).to eq("true")
      expect(row.at_css(".fp-q-kind[data-fp-kind='entscheidung']").text).to eq("Entscheidung")
      expect(row.at_css(".fp-q-consequence").text).to include("Folge", "Danach neu bauen")
      expect(row.css("button.fp-q-option").map { |node| [node["value"], node["class"].include?("is-recommended")] })
        .to eq([["A", false], ["B", true]])
      expect(row.at_css("button.is-recommended .fp-q-rec").text).to include("empfohlen")
      expect(row.at_css(".fp-q-hint").text).to include("Enter")
      expect(row.at_css("[data-fp-irreversible]")).to be_nil
    end

    it "marks a not reversible question and offers no Enter hint" do
      question = ask(kind: "freigabe", recommended_option: "A", reversible: false)
      get "/"

      row = page.at_css("#fp-inbox [data-fp-question='#{question.id}']")
      expect(row["data-fp-reversible"]).to eq("false")
      expect(row.at_css("[data-fp-irreversible]").text).to include("nicht umkehrbar")
      expect(row.at_css(".fp-q-hint")).to be_nil
    end

    it "renders an old question without any of the new elements" do
      question = ask
      get "/"

      row = page.at_css("#fp-inbox [data-fp-question='#{question.id}']")
      expect(row.key?("data-fp-recommended")).to be(false)
      expect(row.key?("data-fp-reversible")).to be(false)
      expect(row.at_css(".fp-q-meta, .fp-q-consequence, .fp-q-hint, .is-recommended")).to be_nil
    end

    it "escapes markup in the consequence" do
      ask(consequence: "<script>alert(1)</script>")
      get "/"

      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    end
  end

  describe "the data for the T3 header and the chat" do
    it "gives kind, recommended_option, reversible and consequence in the chat items" do
      question = ask(kind: "zugang", recommended_option: "A", reversible: false, consequence: "Schlüssel nötig")

      item = Flightplan::ChatQuestions.item(question)

      expect(item).to include(kind: "zugang", recommended_option: "A", reversible: false, consequence: "Schlüssel nötig")
      expect(Flightplan::ChatQuestions.item(ask)).to include(kind: nil, recommended_option: nil, reversible: nil, consequence: nil)
    end
  end

  describe "the shadow row" do
    before do
      Flightplan::ShadowDecision.create!(source: "ask", work_package:, chosen: "A", matched: true, would_auto: true, rule: "x")
      Flightplan::ShadowDecision.create!(source: "ask", work_package:, chosen: "B", matched: false, would_auto: true, rule: "x")
    end

    context "as admin" do
      current_user { admin }

      it "shows the counts" do
        get "/"

        expect(page.at_css("#fp-inbox [data-fp-shadow]").text)
          .to eq("Schatten: 2 Fälle, davon 1 wie empfohlen; Regel hätte 2-mal entschieden, davon 1 falsch")
      end
    end

    context "as a reader" do
      current_user { member }

      it "does not show it" do
        get "/"

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("data-fp-shadow")
      end
    end
  end

  describe "locale keys" do
    it "has the same keys in German and English for requests and shadow" do
      %w[requests shadow].each do |group|
        de = I18n.t("flightplan.#{group}", locale: :de)
        en = I18n.t("flightplan.#{group}", locale: :en)
        expect(de).to be_a(Hash)
        expect(en.keys).to match_array(de.keys)
      end
      expect(I18n.t("flightplan.requests.kinds", locale: :en).keys).to match_array(Flightplan::Question::KINDS.map(&:to_sym))
    end
  end

  describe "the dashboard page" do
    current_user { admin }

    it "hands the request labels to the script" do
      get "/"

      labels = JSON.parse(page.at_css("#fp-home")["data-fp-request-labels"])
      expect(labels).to include("approve" => "freigeben", "decline" => "ablehnen", "in_chat" => "im Chat beantworten")
    end
  end
end
