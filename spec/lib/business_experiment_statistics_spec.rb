# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Knowledge::BusinessExperiment do
  let(:options) do
    { name: "test", version: "1", hypothesis: "benefit", unit: "customer",
      metrics: { success: { min: 0, max: 1, direction: "maximize" } }, primary_metric: "success",
      starts_at: "2026-01-01T00:00:00Z", enrollment_ends_at: "2026-01-02T00:00:00Z",
      analysis_at: "2026-01-03T00:00:00Z", window_seconds: 3600, max_units: 1000, min_per_arm: 20,
      gates: { control: "g", treatment: "g" }, variants: { control: { v: 1 }, treatment: { v: 2 } },
      evidence_versions: { ledger: "1" }, journal: double("journal"), authorize: ->(*) { true },
      eligible: ->(*) { true }, bind_unit: ->(*) { true } }
  end
  subject(:experiment) { described_class.new(**options) }

  def rows(n: 100, control: 0, treatment: 1)
    %w[control treatment].flat_map do |arm|
      n.times.map do
        { "assignment" => { "arm" => arm }, "outcome" => { "values" => { "success" => arm == "control" ? control : treatment } }, "exposure" => nil }
      end
    end
  end

  def analyze(data, instance = experiment)
    instance.send(:summarize, data, stopped: false, approved: true)
  end

  it "uses the specified simultaneous bounded confidence radius" do
    result = analyze(rows)
    estimate = result["estimates"]["success"]
    radius = 2 * Math.sqrt(Math.log(80) / 200)
    expect(estimate["benefit_lower"].to_f).to be_within(1e-12).of(1 - radius)
    expect(estimate["benefit_upper"].to_f).to be_within(1e-12).of(1 + radius)
    expect(result["status"]).to eq("eligible_for_human_review")
  end

  it "does not infer improvement from zero observed variance or equal means" do
    report = analyze(rows(control: 1, treatment: 1))
    expect(report["reasons"]).to include("primary_inconclusive")
    expect(report["estimates"]["success"]["benefit_upper"].to_f).to be > 0
  end

  it "orients minimizing metrics correctly" do
    lower = described_class.new(**options.merge(metrics: { success: { min: 0, max: 1, direction: "minimize" } }))
    report = analyze(rows(control: 1, treatment: 0), lower)
    expect(report["estimates"]["success"]["treatment_minus_control"]).to eq("-1")
    expect(report["status"]).to eq("eligible_for_human_review")
  end

  it "blocks recommendations on guardrails and adjusts for multiple metrics" do
    metrics = options[:metrics].merge(safety: { min: 0, max: 1, direction: "maximize", max_harm: 0 })
    multiple = described_class.new(**options.merge(metrics: metrics))
    data = rows
    data.each { |row| row["outcome"]["values"]["safety"] = row["assignment"]["arm"] == "control" ? 1 : 0 }
    report = analyze(data, multiple)
    expect(report["reasons"]).to include("guardrail_not_established:safety")
    expect(report["estimates"]["success"]["benefit_lower"].to_f).to be < analyze(rows)["estimates"]["success"]["benefit_lower"].to_f
  end

  it "flags allocation imbalance and never drops missing units" do
    data = rows(n: 200).first(200) + rows(n: 20).last(20)
    report = analyze(data)
    expect(report["reasons"]).to include("allocation_imbalance")
    data[0]["outcome"] = nil
    report = analyze(data)
    expect(report["counts"]["control"]["assigned"]).to eq(200)
    expect(report["reasons"]).to include("missing_outcomes")
    expect(report["estimates"]).to be_empty
  end

  it "validates metric ranges, dates, variants and quotas before registration" do
    [{ max_units: 10 }, { primary_metric: "unknown" }, { variants: {} },
     { analysis_at: "2026-01-01T12:00:00Z" }, { metrics: { success: { min: 1, max: 1, direction: "maximize" } } }].each do |change|
      expect { described_class.new(**options.merge(change)) }.to raise_error(Agentkit::Knowledge::InvalidContract)
    end
  end
end
