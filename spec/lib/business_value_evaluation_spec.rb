# frozen_string_literal: true
require "spec_helper"

RSpec.describe Agentkit::Harness::BusinessValueEvaluation do
  let(:digest) { ->(value) { Agentkit::Knowledge.digest(value) } }
  let(:cases) do
    [{ id: "refund-approved", phase: "training", category: "verified_refund", input_digest: digest.call("approved") },
     { id: "refund-missing-proof", phase: "holdout", category: "incomplete_evidence", input_digest: digest.call("missing") }]
  end
  let(:observations) do
    cases.flat_map do |test|
      %w[baseline candidate].map do |arm|
        { case_id: test.fetch(:id), arm: arm, input_digest: test.fetch(:input_digest),
          evidence_digest: digest.call([test.fetch(:id), arm]),
          verified: true, safety_failures: [],
          cost_microusd: arm == "baseline" ? 200 : 100,
          latency_ms: arm == "baseline" ? 1000 : 500,
          human_seconds: arm == "baseline" ? 60 : 30, tokens: 100 }
      end
    end
  end

  def report(steps = observations)
    described_class.new(id: "returns-v1", version: "1", cases: cases, observations: steps).to_h
  end

  it "reports paired business value in training and holdout without promotion" do
    result = report
    expect(result).to include("causal" => false, "authorizes" => false, "auto_promoted" => false)
    expect(result.dig("phases", "holdout", "delta")).to include(
      "cost_microusd" => -100, "human_seconds" => -30, "verified" => 0)
    expect(result.dig("phases", "training", "arms", "candidate", "cost_per_verified_microusd")).to eq(100)
    expect(result.fetch("contract_digest")).to match(/\A[0-9a-f]{64}\z/)
  end

  it "does not count a safety failure as a verified result and identifies the holdout regression" do
    changed = observations.map(&:dup)
    item = changed.find { |row| row[:case_id] == "refund-missing-proof" && row[:arm] == "candidate" }
    item[:safety_failures] = ["unauthorized_refund"]
    result = report(changed)
    expect(result.dig("phases", "holdout", "candidate_regressions")).to eq(["refund-missing-proof"])
    expect(result.dig("phases", "holdout", "arms", "candidate", "verified")).to eq(0)
    expect(result.dig("phases", "holdout", "arms", "candidate", "cost_per_verified_microusd")).to be_nil
  end

  it "fails closed on missing arms, duplicate receipts, mismatched inputs and missing measurements" do
    expect { report(observations.drop(1)) }.to raise_error(Agentkit::Knowledge::InvalidContract)
    duplicate = observations.map(&:dup)
    duplicate[1][:evidence_digest] = duplicate[0][:evidence_digest]
    expect { report(duplicate) }.to raise_error(Agentkit::Knowledge::InvalidContract)
    wrong_input = observations.map(&:dup)
    wrong_input[0][:input_digest] = digest.call("different")
    expect { report(wrong_input) }.to raise_error(Agentkit::Knowledge::InvalidContract)
    incomplete = observations.map(&:dup)
    incomplete[0].delete(:human_seconds)
    expect { report(incomplete) }.to raise_error(Agentkit::Knowledge::InvalidContract)
  end

  it "rejects a reused case ID across training and holdout" do
    invalid = cases.map(&:dup)
    invalid.last[:id] = invalid.first[:id]
    expect { described_class.new(id: "returns", version: "1", cases: invalid, observations: observations) }
      .to raise_error(Agentkit::Knowledge::InvalidContract)
  end
end
