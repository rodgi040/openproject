# frozen_string_literal: true

require "#{File.dirname(__FILE__)}/../../spec_helper"
require "tmpdir"

RSpec.describe Flightplan::DashboardSnapshots do
  let(:dir) { Dir.mktmpdir("fp-export") }
  let(:now) { Time.zone.parse("2026-11-04 12:00:00") }

  after { FileUtils.remove_entry(dir) }

  def write(name, content)
    File.write(File.join(dir, name), content.is_a?(String) ? content : JSON.generate(content))
  end

  def read(key)
    described_class.new(dir:, now:).read(key)
  end

  it "reports every source as inactive when the directory is missing" do
    sources = described_class.read_all(dir: File.join(dir, "gibt-es-nicht"), now:)
    expect(sources.keys).to eq(%i[health engine dispatch])
    expect(sources.values).to all(be_inactive)
    expect(sources[:health].reason).to eq(:missing)
  end

  it "reads a fresh health file by its heartbeat" do
    write("status.json", { "gesamt" => "gruen", "heartbeat" => { "epoch" => (now - 60).to_i }, "pruefungen" => [] })
    source = read(:health)
    expect(source.state).to eq(:ok)
    expect(source.age).to be_within(1).of(60)
    expect(source.data["gesamt"]).to eq("gruen")
  end

  it "marks a health file older than 15 minutes as stale but keeps the data" do
    write("status.json", { "gesamt" => "gelb", "heartbeat" => { "epoch" => (now - 16 * 60).to_i } })
    source = read(:health)
    expect(source).to be_stale
    expect(source.data["gesamt"]).to eq("gelb")
  end

  it "uses erzeugt_am for the engine snapshot and a 5 minute window" do
    write("snapshot.json", { "erzeugt_am" => (now - 4 * 60).utc.iso8601, "gesamt" => "gruen" })
    expect(read(:engine).state).to eq(:ok)
    write("snapshot.json", { "erzeugt_am" => (now - 6 * 60).utc.iso8601, "gesamt" => "gruen" })
    expect(read(:engine).state).to eq(:stale)
  end

  it "falls back to the file time when the dispatcher output has no timestamp" do
    write("dispatch.json", { "slots" => { "belegt" => 1, "maximum" => 4, "frei" => 3 } })
    File.utime((now - 60).to_time, (now - 60).to_time, File.join(dir, "dispatch.json"))
    expect(read(:dispatch).state).to eq(:ok)
    File.utime((now - 3600).to_time, (now - 3600).to_time, File.join(dir, "dispatch.json"))
    expect(read(:dispatch).state).to eq(:stale)
  end

  it "treats a timestamp in the future as inactive" do
    write("snapshot.json", { "erzeugt_am" => (now + 2 * 3600).utc.iso8601, "gesamt" => "gruen" })
    expect(read(:engine)).to be_inactive
    expect(read(:engine).reason).to eq(:future)
    write("snapshot.json", { "erzeugt_am" => (now + 30).utc.iso8601, "gesamt" => "gruen" })
    expect(read(:engine).state).to eq(:ok)
  end

  it "does not raise on absurd heartbeat values" do
    [1e30, -1e30, 10**40, -(10**40)].each do |epoch|
      write("status.json", { "gesamt" => "gruen", "heartbeat" => { "epoch" => epoch } })
      expect { read(:health) }.not_to raise_error
    end
    write("status.json", { "gesamt" => "gruen", "heartbeat" => { "epoch" => 10**40 } })
    expect(read(:health)).to be_inactive
  end

  it "treats broken JSON and non-objects as inactive without raising" do
    write("status.json", "{ kaputt")
    expect(read(:health)).to be_inactive
    expect(read(:health).reason).to eq(:invalid)
    write("snapshot.json", "[1, 2]")
    expect(read(:engine)).to be_inactive
  end

  it "does not follow symlinks" do
    target = File.join(dir, "ziel.json")
    File.write(target, JSON.generate("gesamt" => "gruen"))
    File.symlink(target, File.join(dir, "status.json"))
    expect(read(:health)).to be_inactive
    expect(read(:health).reason).to eq(:not_file)
  end

  it "refuses oversized files" do
    write("status.json", "x" * (described_class::MAX_BYTES + 1))
    expect(read(:health).reason).to eq(:too_large)
  end

  it "maps unknown colours to unbekannt" do
    expect(described_class.color("rot")).to eq("rot")
    expect(described_class.color("<script>")).to eq("unbekannt")
    expect(described_class.color(nil)).to eq("unbekannt")
  end
end
