# frozen_string_literal: true
require "spec_helper"

RSpec.describe Agentkit::Knowledge::BusinessLearning do
  let(:k) { Agentkit::Knowledge }
  let(:now) { Time.utc(2026, 10, 25, 12) }
  let(:context) { Struct.new(:tenant_key, :principal, :account).new("shop", "author", nil) }
  let(:reviewer) { Struct.new(:tenant_key, :principal, :account).new("shop", "reviewer", nil) }
  let(:records) { {} }
  let(:journal) do
    double("journal").tap do |j|
      allow(j).to receive(:read) { |kind:, key:, context:| records[[context.tenant_key, kind, key]] }
      requests = {}
      allow(j).to receive(:once) do |kind:, key:, request_digest:, context:, &block|
        index = [context.tenant_key, kind, key]
        raise k::IntegrityError if requests[index] && requests[index] != request_digest
        requests[index] = request_digest
        records[index] ||= block.call
      end
    end
  end
  let(:options) do
    { name: "returns", version: "1", objective: "reduce cost", metrics: { cost: "minimize" },
      constraints: { refunds: "human approval" }, evidence_versions: { rules: "1" },
      window_seconds: 3600, journal: journal, authorize: ->(*) { true }, clock: -> { now } }
  end
  subject(:learning) { described_class.new(**options) }

  def observation(id, at)
    snapshot = double("snapshot", digest: "snapshot-#{id}", data: { "at" => at })
    records[["shop", "execution", id]] = { "status" => "executed", "verdict" => {
      "accepted" => true, "snapshot_digest" => snapshot.digest, "gate_digest" => "gate-1" } }
    allow(journal).to receive(:load_snapshot).with(snapshot.digest, context: context).and_return(snapshot)
    learning.observe(id: id, execution_key: id, context: context)
  end

  def outcome(id)
    learning.outcome(id: id, values: { cost: 10 }, source: "ledger", source_version: "1",
                     observed_at: now.iso8601, context: context)
  end

  def report
    observation("train", "2026-10-25T08:00:00Z")
    outcome("train")
    allow(learning).to receive(:time_now).and_return(now + 7200)
    observation("test", "2026-10-25T12:30:00Z")
    learning.outcome(id: "test", values: { cost: 20 }, source: "ledger", source_version: "1",
                     observed_at: "2026-10-25T14:00:00Z", context: context)
    learning.evaluate(id: "r", observation_ids: %w[train test], split_at: "2026-10-25T12:15:00Z",
                      as_of: "2026-10-25T14:00:00Z", context: context)
  end

  def proposal
    report
    learning.propose(id: "p", report_id: "r", hypothesis: "smaller discount may reduce cost",
                     change: { discount_basis_points: 100 }, expires_at: "2026-11-01T00:00:00Z", context: context)
  end

  it "uses final integer outcomes and preserves temporal provenance" do
    result = report
    expect(result["causal"]).to eq(false)
    expect(result["summaries"]["training"]["metrics"]["cost"]).to eq("sum" => 10, "count" => 1)
    expect(result["rows"].first["observation"]["receipt_digest"]).not_to be_empty
  end

  it "excludes late-arriving outcomes from historical training" do
    observation("train", "2026-10-25T08:00:00Z")
    outcome("train")
    r = learning.evaluate(id: "r", observation_ids: ["train"], split_at: "2026-10-25T10:00:00Z", as_of: now.iso8601, context: context)
    expect(r["rows"][0]["state"]).to eq("missing")
    expect(r["rows"][0]["outcome"]).to be_nil
    expect(r["summaries"]["training"]["metrics"]["cost"]["count"]).to eq(0)
  end

  it "does not treat pending outcomes as successes" do
    observation("pending", "2026-10-25T11:30:00Z")
    expect { outcome("pending") }.to raise_error(k::InvalidContract)
    r = learning.evaluate(id: "r", observation_ids: ["pending"], split_at: "2026-10-25T10:00:00Z", as_of: now.iso8601, context: context)
    expect(r["summaries"]["holdout"]["counts"]).to eq("complete" => 0, "pending" => 1, "missing" => 0)
  end

  it "requires independent human review and supports irreversible revocation" do
    proposal
    expect(learning.active(id: "p", context: context)).to be_nil
    expect { learning.review(id: "p", approve: true, reason: "ok", context: context) }.to raise_error(k::AccessDenied)
    learning.review(id: "p", approve: true, reason: "limited trial", context: reviewer)
    expect(learning.active(id: "p", context: context)["causal"]).to eq(false)
    learning.rollback(id: "p", reason: "adverse signal", context: reviewer)
    expect(learning.active(id: "p", context: context)).to be_nil
  end

  it "rejects expired and dependency-drifted proposals" do
    proposal
    changed = described_class.new(**options.merge(evidence_versions: { rules: "2" }))
    expect { changed.active(id: "p", context: context) }.to raise_error(k::InvalidContract)
    allow(learning).to receive(:time_now).and_return(Time.utc(2026, 11, 2))
    expect { learning.review(id: "p", approve: true, reason: "ok", context: reviewer) }.to raise_error(k::InvalidContract)
  end

  it "rejects conflicting outcomes but accepts exact retries" do
    observation("a", "2026-10-25T08:00:00Z")
    expect(outcome("a")).to eq(outcome("a"))
    expect { learning.outcome(id: "a", values: { cost: 99 }, source: "ledger", source_version: "1", observed_at: now.iso8601, context: context) }.to raise_error(k::IntegrityError)
  end

  it "denies unauthorized and cross-tenant access" do
    proposal
    denied = described_class.new(**options.merge(authorize: ->(*) { false }))
    expect { denied.active(id: "p", context: context) }.to raise_error(k::AccessDenied)
    other = context.dup
    other.tenant_key = "other"
    expect { learning.active(id: "p", context: other) }.to raise_error(k::InvalidContract)
  end

  it "records the applied proposal version without creating a knowledge rule" do
    proposed = proposal
    learning.review(id: "p", approve: true, reason: "pilot", context: reviewer)
    observation("next", "2026-10-25T13:00:00Z")
    used = learning.observe(id: "used", execution_key: "next", applied_proposal_id: "p", context: context)
    expect(used["applied_proposal_digest"]).to eq(k.digest(proposed))
    expect(learning.fetch(type: "observation", id: "used", context: context)).to eq(used)
    expect(used["process_contract"]).to eq(learning.contract)
  end

  it "rejects unknown executions, future cuts, duplicate cohort IDs and incomplete metrics" do
    expect { learning.observe(id: "a", execution_key: "unknown", context: context) }.to raise_error(k::InvalidContract)
    observation("a", "2026-10-25T08:00:00Z")
    expect { learning.outcome(id: "a", values: {}, source: "ledger", source_version: "1", observed_at: now.iso8601, context: context) }.to raise_error(k::InvalidContract)
    args = { id: "r", observation_ids: ["a"], split_at: "2026-10-25T10:00:00Z", as_of: now.iso8601, context: context }
    expect { learning.evaluate(**args.merge(observation_ids: %w[a a])) }.to raise_error(k::InvalidContract)
    expect { learning.evaluate(**args.merge(as_of: "2026-10-26T12:00:00Z")) }.to raise_error(k::InvalidContract)
    learning.observe(id: "alias", execution_key: "a", context: context)
    expect { learning.evaluate(**args.merge(observation_ids: %w[a alias])) }.to raise_error(k::InvalidContract)
    changed = described_class.new(**options.merge(evidence_versions: { gate: "different" }))
    expect { changed.observe(id: "a", execution_key: "a", context: context) }.to raise_error(k::InvalidContract)
  end
end
