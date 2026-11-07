# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Memory::Evaluation do
  let(:cases) { [{ id: "holdout-1", input: { query: "returns" }, expected: { answer: "invoice" } }] }
  let(:grader) { ->(output, expected) { { correct: output["answer"] == expected["answer"], supported: true, stale_used: false, cross_scope: false } } }

  it "compares three arms without exposing expected answers and includes consolidation cost" do
    runner = ->(arm, input) do
      expect(input.keys).to eq(["query"])
      { answer: arm == "search_only" ? "wrong" : "invoice", evidence_ids: ["policy"], tokens: 100, cost_microusd: 10 }
    end
    report = described_class.compare(cases: cases, runner: runner, grader: grader, consolidation_cost_microusd: 50)
    expect(report.dig("totals", "search_only", "passed")).to eq(0)
    expect(report.dig("totals", "consolidated_memory", "passed")).to eq(1)
    expect(report.dig("totals", "consolidated_memory", "reported_cost_microusd")).to eq(60)
    expect(report["authorizes"]).to be(false)
  end

  it "counts stale or cross-scope answers as failures even when they are correct" do
    runner = ->(*) { { answer: "invoice", evidence_ids: [], tokens: 1, cost_microusd: 1 } }
    report = described_class.compare(cases: cases, runner: runner,
      grader: ->(*) { { correct: true, supported: true, stale_used: true, cross_scope: false } })
    expect(report["rows"].map { |r| r["passed"] }.uniq).to eq([false])
  end

  it "reports errors without pretending that missing cost is a zero-cost success" do
    report = described_class.compare(cases: cases, runner: ->(*) { raise "secret" }, grader: grader)
    expect(report.dig("totals", "current_memory", "cost_complete")).to be(false)
    expect(report.to_s).not_to include("secret")
    expect { described_class.compare(cases: cases * 2, runner: ->(*) {}, grader: grader) }.to raise_error(Agentkit::Knowledge::InvalidContract)
  end
end
