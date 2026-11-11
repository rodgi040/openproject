# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../spec_helper"

# OP#1843: SHADOW_RULE_V1. Die Regel entscheidet nichts; sie sagt nur, ob eine Frage ein Kandidat WÄRE.
RSpec.describe Flightplan::ShadowRule do
  def verdict(**overrides)
    described_class.call(
      **{ source: "ask", kind: "entscheidung", reversible: true, recommended: "A", texts: ["Welche Farbe?", %w[A B], "Nur Optik"] }
        .merge(overrides)
    )
  end

  it "names itself SHADOW_RULE_V1" do
    expect(described_class::VERSION).to eq("SHADOW_RULE_V1")
  end

  it "is true for a clean, reversible decision from ask with a recommendation" do
    result = verdict
    expect(result.would_auto).to be(true)
    expect(result.reason).to eq("SHADOW_RULE_V1: ja")
  end

  it "is never true for a chat question" do
    result = verdict(source: "chat")
    expect(result.would_auto).to be(false)
    expect(result.reason).to include("Chat")
  end

  it "is false when the kind is not entscheidung or missing" do
    %w[freigabe zugang abnahme].each { |kind| expect(verdict(kind:).would_auto).to be(false) }
    expect(verdict(kind: nil).would_auto).to be(false)
    expect(verdict(kind: "freigabe").reason).to include("entscheidung")
  end

  it "is false when not reversible or reversibility is unknown" do
    expect(verdict(reversible: false).would_auto).to be(false)
    expect(verdict(reversible: nil).would_auto).to be(false)
    expect(verdict(reversible: "true").would_auto).to be(false)
  end

  it "is false without a recommendation" do
    expect(verdict(recommended: nil).would_auto).to be(false)
    expect(verdict(recommended: "  ").would_auto).to be(false)
  end

  it "reports the first reason for no" do
    expect(verdict(source: "chat", kind: "freigabe").reason).to include("Chat")
    expect(verdict(kind: "freigabe", reversible: false).reason).to include("entscheidung")
  end

  describe "reserved words" do
    {
      "Deploy jetzt?" => "deploy", "Release freigeben?" => "release", "Patch einspielen?" => "einspiel",
      "Die Änderung ist eingespielt" => "eingespiel", "In Produktion nehmen?" => "produktion",
      "Auf dem Host ausführen?" => "host", "Docker neu starten?" => "docker", "Firewall-Regel ändern?" => "firewall",
      "SSH-Zugang öffnen?" => "ssh", "Port 8080 öffnen?" => "port", "DNS umstellen?" => "dns", "Secret ablegen?" => "secret",
      "Token erneuern?" => "token", "Passwort ändern?" => "passwort", "Rotation jetzt?" => "rotation",
      "Datei löschen?" => "lösch", "Ist das unumkehrbar?" => "unumkehr", "Force-Push nötig?" => "force",
      "Direkt auf main?" => "main", "Kostet das etwas?" => "kost", "Budget erhöhen?" => "budget", "Die Kosten steigen" => "kost", "Geld ausgeben?" => "geld",
      "Anderes Modell nutzen?" => "modell", "Kunde informieren?" => "kund", "Mail senden?" => "mail", "Versand starten?" => "versand",
      "Vertrag ändern?" => "vertrag", "Scope erweitern?" => "scope", "Priorität erhöhen?" => "priorit",
      "Architektur ändern?" => "architektur", "Zuständigkeit klären?" => "zuständig", "Startfreigabe erteilen?" => "startfreigabe",
      "Gate öffnen?" => "gate", "Prüfer wechseln?" => "prüfer",
      "Deploy to production?" => "deploy", "Rotate the keys" => "rotate", "Reset the password" => "password", "Delete the file" => "delete",
      "Not reversible" => "not reversible", "Change the customer email" => "customer", "Raise the cost" => "cost",
      "Use another model" => "model", "Expand the scope" => "scope", "Reassign ownership" => "ownership",
      "Change the architecture" => "architecture", "Pick the reviewer" => "reviewer", "Shipping now" => "shipping",
      "Sign the contract" => "contract", "Raise the priority" => "priorit", "Set the budget" => "budget",
      "Force push" => "force", "Open the firewall" => "firewall", "Start approval" => "start approval"
    }.each do |text, stem|
      it "blocks #{text.inspect}" do
        expect(described_class.reserved_word(text)).to eq(stem)
        result = verdict(texts: [text])
        expect(result.would_auto).to be(false)
        expect(result.reason).to include("Vorbehaltswort")
      end
    end

    it "looks into the question, every option and the context" do
      expect(verdict(texts: ["Docker?", %w[A B], nil]).would_auto).to be(false)
      expect(verdict(texts: ["Variante?", ["A", "Deployment"], nil]).would_auto).to be(false)
      expect(verdict(texts: ["Variante?", %w[A B], "läuft im Produktionsnetz"]).would_auto).to be(false)
    end

    it "ignores case" do
      expect(described_class.reserved_word("DOCKER")).to eq("docker")
      expect(verdict(texts: ["PASSWORT"]).would_auto).to be(false)
    end

    it "respects word boundaries: Portierung, Transport and Portal are no port" do
      ["Portierung auf Rust", "Transport der Daten", "Portal", "domain", "maintain", "remaining", "Hostile", "Dnsmasq"].each do |text|
        expect(described_class.reserved_word(text)).to be_nil, "#{text} must not hit"
      end
      expect(verdict(texts: ["Portierung der Funktion", %w[A B], "Nur Optik"]).would_auto).to be(true)
    end

    it "still matches plural and compound forms of the long stems" do
      ["Ports", "Hosts", "Deployment", "Produktionsumgebung", "Dockerfile", "Kunden", "Verträge", "Passwörter"].each do |text|
        expect(described_class.reserved_word(text)).to be_present, "#{text} must hit"
      end
    end

    it "lists every word of the contract" do
      contract = %w[deploy release einspiel produktion host docker firewall ssh port dns secret token passwort rotation lösch
                    unumkehr force main geld budget kost modell kund mail versand vertrag scope priorit architektur zuständig
                    startfreigabe gate prüfer]
      expect(described_class::RESERVED_WORDS).to include(*contract)
    end
  end
end
