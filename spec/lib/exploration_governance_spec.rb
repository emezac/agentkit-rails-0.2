# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Exploration::Governance do
  before do
    Agentkit.config.exploration.store = :memory
    described_class.store = described_class::Stores::Memory.new
  end

  def evaluation(name, version, digest, score)
    Agentkit::Exploration::Evaluation.new(
      policy_name: name, policy_version: version, policy_digest: digest,
      history_digest: "history", world_count: 20, mean_score: score,
      mean_quality: score, mean_attempts: 2.0, mean_rounds: 1.0,
      mean_parallelism: 2.0, mean_coverage: 1.0, min_coverage: 1.0,
      unsupported_actions: 0, replays: []
    )
  end

  def recommendation(candidate_name: "candidate", candidate_version: "2",
                     candidate_digest: "sha256:candidate")
    incumbent = evaluation("incumbent", "1", "sha256:incumbent", 0.5)
    candidate = evaluation(candidate_name, candidate_version, candidate_digest, 0.8)
    comparison = Agentkit::Exploration::StatisticalComparison.new(
      metric: "score", sample_size: 10, mean_difference: 0.3,
      median_difference: 0.3, standard_error: 0.01, ci_lower: 0.2,
      ci_upper: 0.4, confidence_level: 0.95,
      bootstrap_superiority_rate: 0.99, minimum_effect: 0.0,
      significant: true, method: "paired_bootstrap_percentile_v1",
      seed_digest: "sha256:seed"
    )
    Agentkit::Exploration::Recommendation.new(
      status: "recommend_review", level: "n3", incumbent: "incumbent",
      selected: candidate_name, evaluations: [incumbent, candidate],
      holdout_evaluations: [incumbent, candidate], pareto_frontier: [],
      holdout: { assignment_digest: "sha256:split" }, comparison: comparison,
      requires_review: true, auto_promoted: false,
      reason: "statistically_significant_holdout_improvement"
    )
  end

  it "persists an idempotent, bounded evidence dossier" do
    first = described_class.submit!(target: "support.search", recommendation: recommendation)
    second = described_class.submit!(target: "support.search", recommendation: recommendation)

    expect(second.id).to eq(first.id)
    expect(first).to be_pending
    expect(first.evidence.fetch("training").first).not_to have_key("replays")
    expect(first.evidence_digest).to start_with("sha256:")
    expect(described_class.reviews).to contain_exactly(first)
  end

  it "approves and rolls back a binding without mutating the policy registry" do
    review = described_class.submit!(target: "support.search", recommendation: recommendation)
    policy = Object.new
    policy.define_singleton_method(:select) { |_view| [] }
    before = Agentkit::Exploration.policies.register("candidate", version: "2", policy: policy)

    approved = described_class.approve!(review, actor: "human:42", reason: "reviewed")
    binding = described_class.binding("support.search")

    expect(approved).to be_approved
    expect(binding.policy_digest).to eq("sha256:candidate")
    expect(binding.review_id).to eq(review.id)
    expect(Agentkit::Exploration.policies.fetch("candidate", version: "2").digest).to eq(before.digest)

    rolled_back = described_class.rollback!(approved, actor: "human:42", reason: "regression")
    expect(rolled_back).to be_rolled_back
    expect(described_class.binding("support.search")).to be_nil
  end

  it "restores the previous approved binding on rollback" do
    first = described_class.submit!(target: "support.search", recommendation: recommendation)
    described_class.approve!(first, actor: "human:42")
    second = described_class.submit!(
      target: "support.search",
      recommendation: recommendation(candidate_name: "candidate-v3",
                                     candidate_version: "3",
                                     candidate_digest: "sha256:candidate-v3")
    )
    described_class.approve!(second, actor: "human:42")

    described_class.rollback!(second, actor: "human:42", reason: "holdout drift")
    restored = described_class.binding("support.search")
    expect(restored.policy_digest).to eq("sha256:candidate")
    expect(restored.review_id).to eq(first.id)
    expect(restored.generation).to eq(3)
  end

  it "requires a reason for rejection and prevents a second decision" do
    review = described_class.submit!(target: "support.search", recommendation: recommendation)

    expect do
      described_class.reject!(review, actor: "human:42", reason: "")
    end.to raise_error(Agentkit::ConfigurationError, /reason is required/)

    described_class.reject!(review, actor: "human:42", reason: "too expensive")
    expect(Agentkit::Audit.entries.map(&:event_type)).to include("exploration.review.rejected")
    expect do
      described_class.approve!(review, actor: "human:42")
    end.to raise_error(Agentkit::DecisionConflict, /already rejected/)
  end

  it "rejects recommendations that have not passed the statistical gate" do
    unsafe = recommendation
    unsafe.comparison.significant = false

    expect do
      described_class.submit!(target: "support.search", recommendation: unsafe)
    end.to raise_error(Agentkit::ConfigurationError, /significant holdout/)
  end

  it "isolates reviews and bindings by tenant" do
    acme = Agentkit::Context.new(account: AgentkitSpecHelpers::Account.new(1, "Acme", "pro"))
    beta = Agentkit::Context.new(account: AgentkitSpecHelpers::Account.new(2, "Beta", "pro"))
    acme_review = Agentkit.with_context(acme) do
      described_class.submit!(target: "support.search", recommendation: recommendation)
    end
    Agentkit.with_context(acme) do
      described_class.approve!(acme_review, actor: "human:1")
    end

    expect(Agentkit.with_context(beta) { described_class.reviews }).to be_empty
    expect(Agentkit.with_context(beta) { described_class.binding("support.search") }).to be_nil
  end

  it "writes required audit events for every accepted transition" do
    review = described_class.submit!(target: "support.search", recommendation: recommendation)
    described_class.approve!(review, actor: "human:42")

    events = Agentkit::Audit.entries.map(&:event_type)
    expect(events).to include("exploration.review.submitted", "exploration.review.approved")
  end

  it "reports readiness and only prunes quota ledgers when maintenance is applied" do
    Agentkit.config.exploration.store = :memory
    old_time = Time.utc(2025, 1, 1)
    Agentkit::Exploration::Quota.reserve!(
      resource: :worlds, amount: 1, reservation_key: "old-world", at: old_time
    )

    dry_run = Agentkit::Exploration.maintain!(dry_run: true, at: Time.utc(2026, 1, 1))
    expect(dry_run).to be_dry_run
    expect(Agentkit::Exploration::Quota.snapshots(at: old_time).fetch(:worlds).used).to eq(1)

    applied = Agentkit::Exploration.maintain!(dry_run: false, at: Time.utc(2026, 1, 1))
    expect(applied.pruned).to include(usages: 1, reservations: 1)
    expect(Agentkit::Exploration::Quota.snapshots(at: old_time).fetch(:worlds).used).to eq(0)
    expect(applied.readiness).to be_ready
    expect(applied.to_h.fetch(:readiness).fetch(:checks)).to include(audit_enabled: true)
  end
end
