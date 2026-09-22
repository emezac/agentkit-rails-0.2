# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Adaptive exploration persistence", :integration do
  def governed_recommendation
    evaluation = lambda do |name, version, digest, score|
      Agentkit::Exploration::Evaluation.new(
        policy_name: name, policy_version: version, policy_digest: digest,
        history_digest: "sha256:history", world_count: 20,
        mean_score: score, mean_quality: score, mean_attempts: 2.0,
        mean_rounds: 1.0, mean_parallelism: 2.0, mean_coverage: 1.0,
        min_coverage: 1.0, unsupported_actions: 0, replays: []
      )
    end
    incumbent = evaluation.call("incumbent", "1", "sha256:incumbent", 0.5)
    candidate = evaluation.call("candidate", "2", "sha256:candidate", 0.8)
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
      selected: "candidate", evaluations: [incumbent, candidate],
      holdout_evaluations: [incumbent, candidate], pareto_frontier: [],
      holdout: { assignment_digest: "sha256:split" }, comparison: comparison,
      requires_review: true, auto_promoted: false,
      reason: "statistically_significant_holdout_improvement"
    )
  end

  it "persists replay worlds and scopes them by tenant" do
    Agentkit.config.exploration.enabled = true
    Agentkit.config.exploration.store = :active_record
    Agentkit::Exploration.store = Agentkit::Exploration::Stores::ActiveRecord.new
    account = account!(name: "Explore A")
    other = account!(name: "Explore B")

    world = with_account(account) do
      Agentkit::Exploration.run(
        objective: "find a better support policy", policy: Agentkit::Exploration::Policies::Portfolio.new,
        generator: ->(**) { { candidate: "digest me" } },
        evaluator: ->(_) { { score: 1.0 } }, evaluator_id: "support-eval-v1",
        max_rounds: 1
      )
    end

    expect(Agentkit::ExplorationWorldRecord.where(tenant_key: "account:#{account.id}").count).to eq(1)
    row = Agentkit::ExplorationWorldRecord.find_by!(world_id: world.id)
    expect(row.checkpoint_version).to eq(1)
    expect(row.evaluator_manifest).to include("digest" => world.evaluator_digest)
    expect(row.lease_owner).to be_nil
    expect(row.lease_expires_at).to be_nil
    attempts = Agentkit::ExplorationAttemptRecord.where(world_id: world.id)
    expect(attempts.pluck(:status)).to eq(["completed"])
    expect(Agentkit::Exploration.store.find(world.id,
      scope: Agentkit::Scope.new(tenant_key: "account:#{account.id}", account_id: account.id))).not_to be_nil
    expect(Agentkit::Exploration.store.find(world.id,
      scope: Agentkit::Scope.new(tenant_key: "account:#{other.id}", account_id: other.id))).to be_nil
  end

  it "has unique durable world ids and scoped indexes" do
    indexes = ActiveRecord::Base.connection.indexes(:agentkit_exploration_worlds)
    attempt_indexes = ActiveRecord::Base.connection.indexes(:agentkit_exploration_attempts)

    expect(indexes.find { |index| index.name == "index_agentkit_exploration_worlds_on_world_id" }.unique).to be(true)
    expect(indexes.map(&:name)).to include("idx_agentkit_exploration_worlds_scope",
                                          "idx_agentkit_exploration_worlds_policy",
                                          "idx_agentkit_exploration_worlds_lease",
                                          "idx_agentkit_exploration_worlds_operations")
    expect(attempt_indexes.find { |index| index.name == "idx_agentkit_exploration_attempts_slot" }.unique)
      .to be(true)
    expect(attempt_indexes.find { |index| index.name == "idx_agentkit_exploration_attempts_idempotency" }.unique)
      .to be(true)
    usage_index = ActiveRecord::Base.connection.indexes(:agentkit_exploration_quota_usages)
                                    .find { |index| index.name == "idx_agentkit_exploration_quota_usage" }
    reservation_index = ActiveRecord::Base.connection.indexes(:agentkit_exploration_quota_reservations)
                                          .find do |index|
      index.name == "idx_agentkit_exploration_quota_reservation"
    end
    expect(usage_index.unique).to be(true)
    expect(usage_index.columns).to eq(%w[tenant_key account_id resource period_start])
    expect(reservation_index.unique).to be(true)
    expect(reservation_index.columns).to eq(%w[tenant_key account_id resource reservation_key])
    review_index = ActiveRecord::Base.connection.indexes(:agentkit_exploration_reviews)
                                     .find { |index| index.name == "idx_agentkit_exploration_review_evidence" }
    binding_index = ActiveRecord::Base.connection.indexes(:agentkit_exploration_policy_bindings)
                                      .find { |index| index.name == "idx_agentkit_exploration_policy_binding" }
    expect(review_index.unique).to be(true)
    expect(binding_index.unique).to be(true)
  end

  it "persists governed recommendations and reverses their declarative binding" do
    account = account!(name: "Governed")
    review = with_account(account) do
      Agentkit::Exploration.submit_recommendation!(
        target: "support.search", recommendation: governed_recommendation
      )
    end

    expect(Agentkit::ExplorationReviewRecord.find_by!(dossier_id: review.id).status).to eq("pending")
    approved = with_account(account) do
      Agentkit::Exploration.approve_recommendation!(review, actor: "human:operator")
    end
    binding = Agentkit::ExplorationPolicyBindingRecord.find_by!(dossier_id: review.id)
    expect(approved.status).to eq("approved")
    expect(binding.policy_digest).to eq("sha256:candidate")

    with_account(account) do
      Agentkit::Exploration.rollback_recommendation!(
        review, actor: "human:operator", reason: "production regression"
      )
    end
    expect(Agentkit::ExplorationPolicyBindingRecord.find_by(dossier_id: review.id)).to be_nil
    expect(Agentkit::ExplorationReviewRecord.find_by!(dossier_id: review.id).status).to eq("rolled_back")
    expect(Agentkit::AuditRecord.where(account_id: account.id)
                                .where(event_type: %w[exploration.review.submitted
                                                      exploration.review.approved
                                                      exploration.review.rolled_back]).count).to eq(3)
  end

  it "allows exactly one winner in a concurrent promotion decision", :real_concurrency do
    account = account!(name: "Concurrent Governance")
    review = with_account(account) do
      Agentkit::Exploration.submit_recommendation!(
        target: "support.search", recommendation: governed_recommendation
      )
    end
    scope = Agentkit::Scope.new(tenant_key: "account:#{account.id}", account_id: account.id)
    ready = Queue.new
    start = Queue.new
    operations = %i[approve reject]
    results = operations.map do |operation|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          if operation == :approve
            Agentkit::Exploration.approve_recommendation!(review, actor: "human:approve", scope: scope)
          else
            Agentkit::Exploration.reject_recommendation!(
              review, actor: "human:reject", reason: "risk review", scope: scope
            )
          end
          :won
        rescue Agentkit::DecisionConflict
          :conflict
        end
      end
    end
    operations.size.times { ready.pop }
    operations.size.times { start << true }

    expect(results.map(&:value)).to contain_exactly(:won, :conflict)
    row = Agentkit::ExplorationReviewRecord.find_by!(dossier_id: review.id)
    expect(%w[approved rejected]).to include(row.status)
    binding = Agentkit::ExplorationPolicyBindingRecord.find_by(dossier_id: review.id)
    expect(binding.nil?).to eq(row.status == "rejected")
  end

  it "executes a queued registry-backed world through Active Job and accounts quotas once" do
    Agentkit.config.exploration.enabled = true
    Agentkit.config.exploration.execution = :distributed
    Agentkit.config.exploration.store = :active_record
    Agentkit.config.exploration.daily_world_limit = 2
    Agentkit.config.exploration.daily_attempt_limit = 2
    Agentkit::Exploration.store = Agentkit::Exploration::Stores::ActiveRecord.new
    Agentkit::Exploration::Quota.store = Agentkit::Exploration::Quota::ActiveRecordStore.new
    Agentkit::Exploration.generators.register(
      :job_generator, version: "1", generator: ->(**) { { candidate: 1 } },
      source_digest: "job-generator-v1"
    )
    Agentkit::Exploration.evaluators.register(
      :job_evaluator, version: "1", evaluator: ->(_) { { score: 1.0 } },
      source_digest: "job-evaluator-v1"
    )
    account = account!(name: "Distributed")

    queued = with_account(account) do
      Agentkit::Exploration.enqueue(
        objective: "private job objective",
        generator: :job_generator, generator_version: "1",
        evaluator: :job_evaluator, evaluator_version: "1", max_rounds: 1
      )
    end
    row = Agentkit::ExplorationWorldRecord.find_by!(world_id: queued.id)

    expect(row.status).to eq("completed")
    expect(row.generator_manifest).to include("name" => "job_generator", "version" => "1")
    expect(row.tree.to_s).not_to include("private job objective")
    expect(Agentkit::ExplorationQuotaUsageRecord.where(tenant_key: "account:#{account.id}")
                                                .pluck(:resource, :used).to_h)
      .to eq("attempts" => 1, "worlds" => 1)
    scope = Agentkit::Scope.new(tenant_key: "account:#{account.id}", account_id: account.id)
    duplicate_quota = Agentkit::Exploration::Quota.reserve!(
      resource: :worlds, amount: 1, reservation_key: "world:#{queued.id}", scope: scope
    )
    expect(duplicate_quota.used).to eq(1)

    expect do
      Agentkit::ExplorationWorldJob.perform_now(
        queued.id, { tenant_key: "account:#{account.id}", account_id: account.id }
      )
    end.not_to change(Agentkit::ExplorationAttemptRecord, :count)
  end

  it "renders the governed operations dashboard behind the console guard" do
    Agentkit.config.multi_tenant = false
    Agentkit.config.console.enabled = true
    Agentkit.config.console.principal_resolver = -> { "operator:9" }
    Agentkit.config.console.guard = ->(principal) { principal == "operator:9" }
    Agentkit::Exploration.submit_recommendation!(
      target: "support.search", recommendation: governed_recommendation
    )

    status, headers, body = Rails.application.call(
      Rack::MockRequest.env_for("/agentkit/exploration")
    )

    expect(status).to eq(200)
    expect(headers["cache-control"]).to include("no-store")
    expect(body.each.to_a.join).to include("Worlds recientes", "Revisión de promociones",
                                           "binding declarativo auditable", "Aprobar", "Rechazar")
  end
end
