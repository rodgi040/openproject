# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../spec_helper"

# OP#1784: Kontext eines Tickets für die Kopfleiste in T3. Das Dashboard holt ihn nach einem Ticket-Klick oder einem
# Thread-Wechsel in T3 (fp:thread) und gibt ihn als fp:context weiter. Nur Admin, nur offene sichtbare Tickets.
RSpec.describe "Flightplan chat ticket context", :skip_csrf, type: :rails_request do
  def ensure_status(name, closed: false)
    Status.find_by(name:) || create(:status, name:, is_closed: closed)
  end

  let!(:task_type) { Type.find_by(name: "Aufgabe") || create(:type, name: "Aufgabe") }
  let!(:project) { create(:project, name: "Kopf Fabrik", identifier: "kopf-fabrik", public: false, types: [task_type]) }
  let(:admin) { create(:admin, language: "de") }
  let(:agent) { create(:user, firstname: "Coding", lastname: "Claude Code") }
  let!(:open_ticket) do
    create(:work_package, project:, type: task_type, status: ensure_status("Wartet auf Mensch"), assigned_to: agent,
                          subject: "<b>Kopf</b> & Leiste", description: "Beschreibung mit <em>HTML</em>")
  end
  let!(:closed_ticket) do
    create(:work_package, project:, type: task_type, status: ensure_status("Geschlossen", closed: true), subject: "Zu")
  end

  def context_for(id)
    get "/flightplan/chat/context", params: { wp: id }, headers: { "ACCEPT" => "application/json" }
    JSON.parse(response.body)
  end

  describe "as admin" do
    current_user { admin }

    it "returns the fields of the ticket bar with the status label of the ticket picker" do
      wp = context_for(open_ticket.id)["wp"]

      expect(response).to have_http_status(:ok)
      expect(wp).to include(
        "id" => open_ticket.id, "subject" => "<b>Kopf</b> & Leiste", "project" => "kopf-fabrik",
        "project_name" => "Kopf Fabrik", "status" => "Wartet auf Mensch", "status_key" => "waiting",
        "status_label" => "Wartet", "type" => "Aufgabe", "assignee" => agent.name,
        "description" => "Beschreibung mit HTML"
      )
      expect(wp["priority"]).to eq(open_ticket.priority.name)
      expect(Time.iso8601(wp["updated_at"])).to be_within(1.second).of(open_ticket.updated_at)
      expect(wp["url"]).to eq("/work_packages/#{open_ticket.id}")
    end

    it "answers 404 for a closed or unknown ticket, so T3 shows no bar" do
      expect(context_for(closed_ticket.id)).to eq("ok" => false)
      expect(response).to have_http_status(:not_found)
      expect(context_for(0)).to eq("ok" => false)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "as a project member without admin rights" do
    let(:member) do
      create(:user, member_with_permissions: { project => %i[view_work_packages] })
    end

    current_user { member }

    it "is refused" do
      context_for(open_ticket.id)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
