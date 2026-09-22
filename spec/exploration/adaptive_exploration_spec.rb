# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Exploration do
  class DepthPolicy
    def select(view)
      choice = if view.round.zero?
                 view.legal_actions.find { |id| id == Agentkit::Exploration::ROOT_ID }
               else
                 view.legal_actions.find { |id| id != Agentkit::Exploration::ROOT_ID }
               end
      [choice].compact
    end
  end

  class BreadthPolicy
    def select(view)
      return [] if view.round >= 2

      [view.legal_actions.find { |id| id == Agentkit::Exploration::ROOT_ID }].compact
    end
  end

  class StopPolicy
    def select(_view) = []
  end

  class IllegalPolicy
    def select(_view) = ["unrevealed-node"]
  end

  class InterruptOncePolicy
    def initialize = @interrupted = false

    def select(view)
      unless @interrupted
        @interrupted = true
        raise Interrupt, "simulated process interruption"
      end
      return [] if view.round >= 1

      [view.legal_actions.first].compact
    end
  end

  class InterruptOnceGenerator
    def initialize = @interrupted = false

    def call(**)
      unless @interrupted
        @interrupted = true
        raise Interrupt, "simulated ambiguous execution"
      end

      { candidate: "resumed" }
    end
  end

  before do
    Agentkit.config.exploration.enabled = true
    Agentkit.config.exploration.store = :memory
    Agentkit.config.exploration.max_rounds = 3
    Agentkit.config.exploration.replay_max_rounds = 8
    Agentkit.config.exploration.max_parallelism = 2
    Agentkit.config.exploration.max_nodes = 8
    Agentkit.config.exploration.min_replay_worlds = 2
    Agentkit.config.exploration.min_replay_coverage = 0.8
    Agentkit.config.exploration.holdout_fraction = 0.5
    Agentkit.config.exploration.holdout_seed = "exploration-spec"
    Agentkit.config.exploration.min_training_worlds = 2
    Agentkit.config.exploration.min_holdout_worlds = 2
    Agentkit.config.exploration.bootstrap_samples = 500
    Agentkit.config.exploration.confidence_level = 0.95
    Agentkit.config.exploration.min_score_improvement = 0.0
    Agentkit.config.exploration.pareto_epsilon = 1e-9
    Agentkit.config.exploration.attempt_stale_after = 0
    Agentkit.config.exploration.resume_lease = 0
    described_class.store = Agentkit::Exploration::Stores::Memory.new
  end

  def sample_world(id: SecureRandom.uuid, created_at: Time.now.utc, scale: 1.0)
    node = Agentkit::Exploration::Node
    Agentkit::Exploration::World.new(
      id: id, objective_digest: "sha256:objective", policy_name: "incumbent",
      policy_version: "1", policy_digest: "sha256:policy",
      evaluator_digest: "sha256:evaluator", tenant_key: "__global__",
      bounds: { max_rounds: 3, max_parallelism: 2, max_nodes: 8,
                beta: 0.6, baseline_score: 0.0 }, rounds: 2,
      status: "completed", stop_reason: "round_limit", created_at: created_at,
      nodes: [
        node.new(id: "root", parent_id: nil, sequence: 0),
        node.new(id: "a", parent_id: "root", sequence: 1, score: 1.0 * scale),
        node.new(id: "b", parent_id: "root", sequence: 2, score: 5.0 * scale),
        node.new(id: "a2", parent_id: "a", sequence: 3, score: 10.0 * scale),
        node.new(id: "b2", parent_id: "b", sequence: 4, score: 6.0 * scale)
      ], metadata: {}
    )
  end

  it "runs bounded online batches and records only digests for the objective and artifact" do
    generator = lambda do |parent:, view:|
      { "parent_score" => parent&.score.to_f, "round" => view.round,
        "secret" => "sk-private-token-1234567890" }
    end
    evaluator = ->(candidate) { { score: candidate["parent_score"] + 1.0, diagnostics: { ok: true } } }

    world = described_class.run(objective: "sensitive objective", generator: generator,
                                evaluator: evaluator, evaluator_id: "fixed-eval-v1",
                                max_rounds: 99, max_parallelism: 99)

    expect(world.rounds).to eq(3)
    expect(world.bounds.fetch("max_rounds")).to eq(3)
    expect(world.bounds.fetch("max_parallelism")).to eq(2)
    expect(world.objective_digest).to start_with("sha256:")
    expect(world.to_h.to_s).not_to include("sensitive objective", "sk-private-token")
    expect(world.nodes.reject(&:root?).map(&:artifact_digest)).to all(start_with("sha256:"))
    expect(emitted("exploration.online.completed").size).to eq(1)
    attempts = described_class.attempts(world: world)
    expect(attempts.size).to eq(world.node_count)
    expect(attempts.map(&:status).uniq).to eq(["completed"])
    expect(attempts.map(&:idempotency_key).uniq.size).to eq(attempts.size)
  end

  it "persists an initial checkpoint and resumes after a clean interruption" do
    policy = InterruptOncePolicy.new
    generator = ->(**) { { candidate: 1 } }
    evaluator = ->(_) { { score: 1.0 } }

    expect do
      described_class.run(objective: "resume me", policy: policy, generator: generator,
                          evaluator: evaluator, evaluator_id: "resume-eval", max_rounds: 2)
    end.to raise_error(Interrupt)

    checkpoint = described_class.store.all(scope: Agentkit::Scope.resolve,
                                            include_incomplete: true).fetch(0)
    expect(checkpoint.status).to eq("running")
    expect(checkpoint.rounds).to eq(0)

    resumed = described_class.resume(world: checkpoint.id, policy: policy,
                                     generator: generator, evaluator: evaluator,
                                     evaluator_id: "resume-eval")
    expect(resumed.status).to eq("completed")
    expect(resumed.rounds).to eq(1)
    expect(resumed.node_count).to eq(1)
  end

  it "marks an interrupted claimed attempt unknown and requires explicit reconciliation" do
    generator = InterruptOnceGenerator.new
    evaluator = ->(_) { { score: 2.0 } }
    policy = BreadthPolicy.new

    expect do
      described_class.run(objective: "ambiguous", policy: policy, generator: generator,
                          evaluator: evaluator, evaluator_id: "ambiguous-eval", max_rounds: 1)
    end.to raise_error(Interrupt)
    checkpoint = described_class.store.all(scope: Agentkit::Scope.resolve,
                                            include_incomplete: true).fetch(0)

    expect do
      described_class.resume(world: checkpoint.id, policy: policy, generator: generator,
                             evaluator: evaluator, evaluator_id: "ambiguous-eval")
    end.to raise_error(Agentkit::ReconciliationRequired, /ambiguous attempts/)

    attempt = described_class.attempts(world: checkpoint.id).fetch(0)
    expect(attempt.status).to eq("execution_unknown")
    described_class.reconcile_attempt!(attempt.id, status: :pending)
    audit = Agentkit::Audit.entries(event_type: "exploration.attempt.reconciled").last
    expect(audit.tenant_key).to eq("__global__")
    expect(audit.payload).to include("attempt_id" => attempt.id, "world_id" => checkpoint.id)

    resumed = described_class.resume(world: checkpoint.id, policy: policy,
                                     generator: generator, evaluator: evaluator,
                                     evaluator_id: "ambiguous-eval")
    expect(resumed.status).to eq("completed")
    expect(described_class.attempts(world: resumed).map(&:status)).to eq(["completed"])
  end

  it "rejects a concurrent resume while a world lease is active" do
    store = described_class.store
    world = sample_world(id: "leased-world")
    running = Agentkit::Exploration::World.from_h(
      world.to_h.merge(status: "running", stop_reason: nil, completed_at: nil, rounds: 0,
                       nodes: [world.root.to_h])
    )
    store.save(running)
    store.acquire_world(running.id, owner: "worker-a", ttl: 60, scope: Agentkit::Scope.resolve)

    expect do
      store.acquire_world(running.id, owner: "worker-b", ttl: 60, scope: Agentkit::Scope.resolve)
    end.to raise_error(Agentkit::ExplorationInProgress, /already being resumed/)
  end

  it "fences stale checkpoint writers after lease takeover" do
    store = described_class.store
    world = sample_world(id: "fenced-world")
    running = Agentkit::Exploration::World.from_h(
      world.to_h.merge(status: "running", stop_reason: nil, completed_at: nil, rounds: 0,
                       nodes: [world.root.to_h])
    )
    store.save(running)
    store.acquire_world(running.id, owner: "worker-a", ttl: 0, scope: Agentkit::Scope.resolve)
    store.acquire_world(running.id, owner: "worker-b", ttl: 60, scope: Agentkit::Scope.resolve)

    expect do
      store.save(running, lease_owner: "worker-a")
    end.to raise_error(Agentkit::ExplorationInProgress, /ownership changed/)
  end

  it "does not classify a fresh running attempt as ambiguous" do
    Agentkit.config.exploration.attempt_stale_after = 60
    Agentkit.config.exploration.resume_lease = 0
    generator = InterruptOnceGenerator.new
    evaluator = ->(_) { { score: 2.0 } }
    policy = BreadthPolicy.new

    expect do
      described_class.run(objective: "still active", policy: policy, generator: generator,
                          evaluator: evaluator, evaluator_id: "active-eval", max_rounds: 1)
    end.to raise_error(Interrupt)
    checkpoint = described_class.store.all(scope: Agentkit::Scope.resolve,
                                            include_incomplete: true).fetch(0)

    expect do
      described_class.resume(world: checkpoint.id, policy: policy, generator: generator,
                             evaluator: evaluator, evaluator_id: "active-eval")
    end.to raise_error(Agentkit::ExplorationInProgress, /active attempts/)
    expect(described_class.attempts(world: checkpoint.id).fetch(0).status).to eq("running")
  end

  it "keeps adaptive exploration disabled by default" do
    Agentkit.config.exploration.enabled = false

    expect do
      described_class.run(objective: "x", policy: StopPolicy.new, generator: ->(**) { {} },
                          evaluator: ->(_) { { score: 0 } }, evaluator_id: "eval")
    end.to raise_error(Agentkit::ConfigurationError, /disabled/)
  end

  it "replays a frozen prefix without invoking a generator or evaluator" do
    world = sample_world
    result = described_class.replay(world: world, policy: DepthPolicy.new,
                                    max_parallelism: 1, cost_penalty: 0.1,
                                    parallelism_bonus: 0.0)

    expect(result.revealed_node_ids).to eq(%w[root a a2])
    expect(result.best_score).to eq(10.0)
    expect(result.score).to be_within(0.0001).of(9.8)
    expect(result.stop_reason).to eq("policy_stop")
  end

  it "rejects distributed enqueue on a process-local store" do
    generator = ->(**) { { candidate: 1 } }
    evaluator = ->(_) { { score: 1.0 } }
    described_class.generators.register(:distributed_generator, version: "1",
                                        generator: generator, source_digest: "generator-v1")
    described_class.evaluators.register(:distributed_evaluator, version: "1",
                                        evaluator: evaluator, source_digest: "evaluator-v1")
    Agentkit.config.exploration.execution = :distributed

    expect do
      described_class.enqueue(
        objective: "private distributed objective",
        generator: :distributed_generator, generator_version: "1",
        evaluator: :distributed_evaluator, evaluator_version: "1",
        max_rounds: 1
      )
    end.to raise_error(Agentkit::ConfigurationError, /migrated ActiveRecord/)
    expect(described_class.store.all(include_incomplete: true)).to be_empty
  end

  it "binds generator name and version to immutable source provenance" do
    described_class.generators.register(
      :discovery, version: "1", generator: ->(**) { { candidate: 1 } },
      source_digest: "discovery-v1"
    )

    expect do
      described_class.generators.register(
        :discovery, version: "1", generator: ->(**) { { candidate: 2 } },
        source_digest: "changed-discovery"
      )
    end.to raise_error(Agentkit::ConfigurationError, /without a version bump/)
  end

  it "preserves the digest and shape of historical schema-v1 worlds" do
    legacy_payload = sample_world(id: "legacy-v1").to_h
                       .merge(schema_version: 1)
                       .reject { |key, _| %i[generator_digest generator_manifest].include?(key) }
    expected_digest = described_class.digest_for(
      legacy_payload.reject { |key, _| %i[created_at completed_at].include?(key) }
    )

    loaded = Agentkit::Exploration::World.from_h(legacy_payload)

    expect(loaded.schema_version).to eq(1)
    expect(loaded.to_h).not_to include(:generator_digest, :generator_manifest)
    expect(loaded.digest).to eq(expected_digest)
  end

  it "reserves daily quotas idempotently and rejects capacity beyond the tenant limit" do
    Agentkit.config.exploration.daily_world_limit = 1
    scope = Agentkit::Scope.new(tenant_key: "tenant-a")

    first = Agentkit::Exploration::Quota.reserve!(
      resource: :worlds, amount: 1, reservation_key: "world-1", scope: scope
    )
    duplicate = Agentkit::Exploration::Quota.reserve!(
      resource: :worlds, amount: 1, reservation_key: "world-1", scope: scope
    )

    expect(first.used).to eq(1)
    expect(duplicate.used).to eq(1)
    expect do
      Agentkit::Exploration::Quota.reserve!(
        resource: :worlds, amount: 1, reservation_key: "world-2", scope: scope
      )
    end.to raise_error(Agentkit::ExplorationQuotaExceeded) { |error|
      expect(error.resource).to eq("exploration_worlds")
      expect(error.limit).to eq(1)
      expect(error.used).to eq(2)
    }
  end

  it "closes a partial world cleanly when its attempt quota is exhausted" do
    Agentkit.config.exploration.daily_attempt_limit = 1

    world = described_class.run(
      objective: "bounded by attempts", policy: DepthPolicy.new,
      generator: ->(**) { { candidate: 1 } },
      evaluator: ->(_) { { score: 1.0 } }, evaluator_id: "quota-evaluator",
      max_rounds: 3
    )

    expect(world.status).to eq("completed")
    expect(world.stop_reason).to eq("quota_exhausted")
    expect(world.node_count).to eq(1)
    expect(described_class.attempts(world: world).size).to eq(1)
  end

  it "builds a tenant-scoped operational snapshot without objective payloads" do
    %w[tenant-a tenant-b].each do |tenant|
      described_class.run(
        objective: "secret-#{tenant}", policy: StopPolicy.new,
        generator: ->(**) { {} }, evaluator: ->(_) { { score: 1.0 } },
        evaluator_id: "ops-evaluator", max_rounds: 1, scope: { tenant_key: tenant }
      )
    end

    snapshot = described_class.operations(scope: { tenant_key: "tenant-a" })

    expect(snapshot.world_counts.fetch("completed")).to eq(1)
    expect(snapshot.recent_worlds.size).to eq(1)
    expect(snapshot.to_h.to_s).not_to include("secret-tenant-a", "tenant-b")
    expect(snapshot.quotas.fetch(:worlds).fetch(:used)).to eq(1)
  end

  it "never exposes unrevealed outcomes to a replay policy" do
    observations = []
    policy = Object.new
    policy.define_singleton_method(:select) do |view|
      observations << [view.nodes.map(&:id), view.respond_to?(:world)]
      [view.legal_actions.first].compact
    end

    described_class.replay(world: sample_world, policy: policy, max_parallelism: 1)

    expect(observations.first).to eq([%w[root], false])
    expect(observations[1].first).to eq(%w[root a])
    expect(observations[1].first).not_to include("b", "a2")
  end

  it "fails closed on illegal, duplicate, and over-wide policy batches" do
    expect do
      described_class.replay(world: sample_world, policy: IllegalPolicy.new)
    end.to raise_error(Agentkit::ConfigurationError, /illegal actions/)

    duplicate = Object.new.tap { |object| object.define_singleton_method(:select) { |view| [view.legal_actions.first] * 2 } }
    expect do
      described_class.replay(world: sample_world, policy: duplicate)
    end.to raise_error(Agentkit::ConfigurationError, /duplicate/)
  end

  it "keeps beta fixed within an episode and sweeps it only through fresh replays" do
    seen = []
    policy = Object.new
    policy.define_singleton_method(:select) do |view|
      seen << view.beta
      [view.legal_actions.first].compact
    end
    world = sample_world

    described_class.replay(world: world, policy: policy, beta: 0.4)
    expect(seen.uniq).to eq([0.4])

    sweep = described_class.sweep(worlds: [world], betas: [0.2, 0.8])
    expect(sweep.keys).to eq([0.2, 0.8])
    expect(sweep.values.map(&:world_count)).to eq([1, 1])
  end

  it "reports historical action coverage and blocks weakly supported promotion" do
    replay = described_class.replay(world: sample_world, policy: DepthPolicy.new)
    expect(replay.decision_coverage).to eq(0.8)
    expect(replay.unsupported_actions).to eq(1)

    Agentkit.config.exploration.min_replay_coverage = 0.95
    worlds = [sample_world(id: "coverage-train-1"), sample_world(id: "coverage-train-2")]
    holdout = [sample_world(id: "coverage-holdout-1"), sample_world(id: "coverage-holdout-2")]
    recommendation = described_class.recommend(incumbent: BreadthPolicy.new,
                                                candidates: [DepthPolicy.new], worlds: worlds,
                                                holdout_worlds: holdout)
    expect(recommendation.status).to eq("retain")
    expect(recommendation.reason).to eq("insufficient_replay_coverage")
  end

  it "includes the incumbent and only emits a reviewed N3 recommendation" do
    worlds = [sample_world(id: "train-1"), sample_world(id: "train-2")]
    holdout = [sample_world(id: "holdout-1"), sample_world(id: "holdout-2")]
    recommendation = described_class.recommend(incumbent: BreadthPolicy.new,
                                                candidates: [DepthPolicy.new], worlds: worlds,
                                                holdout_worlds: holdout)

    expect(recommendation.status).to eq("recommend_review")
    expect(recommendation.selected).to eq("DepthPolicy")
    expect(recommendation.level).to eq("n3")
    expect(recommendation.requires_review).to be(true)
    expect(recommendation.auto_promoted).to be(false)
    expect(recommendation.reason).to eq("statistically_significant_holdout_improvement")
    expect(recommendation.comparison.ci_lower).to be > 0
    expect(recommendation.holdout).to include(strategy: "explicit", holdout_world_count: 2)
  end

  it "retains the incumbent when history is insufficient" do
    recommendation = described_class.recommend(incumbent: BreadthPolicy.new,
                                                candidates: [DepthPolicy.new], worlds: [sample_world])

    expect(recommendation.status).to eq("retain")
    expect(recommendation.reason).to eq("insufficient_replay_worlds")
  end

  it "computes a deterministic paired bootstrap comparison" do
    worlds = 5.times.map { |index| sample_world(id: "comparison-#{index}") }

    first = described_class.compare(incumbent: BreadthPolicy.new,
                                    candidate: DepthPolicy.new, worlds: worlds)
    second = described_class.compare(incumbent: BreadthPolicy.new,
                                     candidate: DepthPolicy.new, worlds: worlds)

    expect(first.to_h).to eq(second.to_h)
    expect(first.sample_size).to eq(5)
    expect(first.mean_difference).to be > 0
    expect(first.ci_lower).to be > 0
    expect(first.significant).to be(true)
    expect(first.method).to eq("paired_percentile_bootstrap")
  end

  it "keeps non-dominated quality/cost trade-offs on the Pareto frontier" do
    build = lambda do |name, quality, attempts, rounds|
      Agentkit::Exploration::Evaluation.new(
        policy_name: name, policy_version: "1", policy_digest: "sha256:#{name}",
        history_digest: "sha256:history", world_count: 2, mean_score: quality - attempts,
        mean_quality: quality, mean_attempts: attempts, mean_rounds: rounds,
        mean_parallelism: 1.0, mean_coverage: 1.0, min_coverage: 1.0,
        unsupported_actions: 0, replays: []
      )
    end
    quality = build.call("quality", 10.0, 5.0, 3.0)
    efficient = build.call("efficient", 9.0, 3.0, 2.0)
    dominated = build.call("dominated", 8.0, 6.0, 4.0)

    frontier = described_class.pareto_frontier(evaluations: [quality, efficient, dominated])

    expect(frontier.map(&:policy_name)).to contain_exactly("quality", "efficient")
  end

  it "assigns worlds to a stable holdout without reassigning prior history" do
    worlds = 30.times.map { |index| sample_world(id: "split-#{index}") }
    first = described_class.split_holdout(worlds: worlds)
    expanded = described_class.split_holdout(worlds: worlds + [sample_world(id: "split-new")])

    expect(first.training_worlds).not_to be_empty
    expect(first.holdout_worlds).not_to be_empty
    expect(expanded.training_worlds.map(&:id) & worlds.map(&:id))
      .to contain_exactly(*first.training_worlds.map(&:id))
    expect(expanded.holdout_worlds.map(&:id) & worlds.map(&:id))
      .to contain_exactly(*first.holdout_worlds.map(&:id))
  end

  it "uses the stable automatic holdout for a recommendation" do
    worlds = 30.times.map { |index| sample_world(id: "auto-recommend-#{index}") }

    recommendation = described_class.recommend(
      incumbent: BreadthPolicy.new, candidates: [DepthPolicy.new], worlds: worlds
    )

    expect(recommendation.status).to eq("recommend_review")
    expect(recommendation.holdout.fetch(:strategy)).to eq("stable_hash_v1")
    expect(recommendation.holdout.fetch(:training_world_count) +
           recommendation.holdout.fetch(:holdout_world_count)).to eq(30)
    expect(recommendation.comparison.significant).to be(true)
  end

  it "retains the incumbent when an untouched holdout is statistically inconclusive" do
    training = [sample_world(id: "mixed-train-1"), sample_world(id: "mixed-train-2")]
    holdout = 4.times.map do |index|
      hash = sample_world(id: "mixed-holdout-#{index}").to_h
      hash[:nodes].find { |node| node[:id] == "a2" }[:score] = index < 2 ? 10.0 : 1.0
      Agentkit::Exploration::World.from_h(hash)
    end

    recommendation = described_class.recommend(
      incumbent: BreadthPolicy.new, candidates: [DepthPolicy.new],
      worlds: training, holdout_worlds: holdout
    )

    expect(recommendation.status).to eq("retain")
    expect(recommendation.reason).to eq("statistically_inconclusive")
    expect(recommendation.comparison.ci_lower).to be < 0
    expect(recommendation.selected).to eq("BreadthPolicy")
  end

  it "rejects overlapping training and holdout evidence" do
    world = sample_world(id: "leaked-world")

    expect do
      described_class.split_holdout(worlds: [world], holdout_worlds: [world])
    end.to raise_error(Agentkit::ConfigurationError, /disjoint/)
  end

  it "validates statistical evaluation settings fail closed" do
    settings = Agentkit::ExplorationSettings.new(
      holdout_fraction: 1.0, holdout_seed: " ", confidence_level: 0.0,
      bootstrap_samples: "not-an-integer", min_score_improvement: -0.1
    )

    problems = settings.validate.join(" ")
    expect(problems).to include("holdout_fraction", "holdout_seed", "confidence_level",
                                "bootstrap_samples", "min_score_improvement")
  end

  it "validates distributed storage and quota settings fail closed" do
    settings = Agentkit::ExplorationSettings.new(
      execution: :distributed, store: :memory, queue: " ",
      daily_world_limit: -1, daily_attempt_limit: "not-an-integer",
      quota_retention_days: 0, quota_resolver: Object.new
    )

    problems = settings.validate.join(" ")
    expect(problems).to include("store must be :active_record", "queue is required",
                                "daily_world_limit", "daily_attempt_limit",
                                "quota_retention_days", "quota_resolver")
  end

  it "isolates in-memory history by tenant" do
    store = Agentkit::Exploration::Stores::Memory.new
    store.save(sample_world(id: "tenant-a"))
    other = Agentkit::Exploration::World.from_h(sample_world(id: "tenant-b").to_h.merge(tenant_key: "tenant:b"))
    store.save(other)

    expect(store.all(scope: Agentkit::Scope.new(tenant_key: "tenant:b")).map(&:id)).to eq(["tenant-b"])
  end

  it "redacts and bounds evaluator diagnostics before persistence" do
    Agentkit.config.exploration.max_diagnostics_bytes = 80
    world = described_class.run(
      objective: "x", policy: BreadthPolicy.new,
      generator: ->(**) { { candidate: 1 } }, evaluator_id: "eval",
      evaluator: ->(_) { { score: 1, diagnostics: { token: "secret", payload: "x" * 500 } } },
      max_rounds: 1
    )

    expect(world.nodes.last.diagnostics).to include("truncated" => true)
    expect(world.to_h.to_s).not_to include("secret", "x" * 100)
  end

  it "records a failed worker as a costed node without inventing a score" do
    world = described_class.run(
      objective: "x", policy: BreadthPolicy.new,
      generator: ->(**) { raise "provider failed with sensitive body" },
      evaluator: ->(_) { raise "must not run" }, evaluator_id: "eval",
      max_rounds: 1
    )

    failed = world.nodes.last
    expect(failed.status).to eq("error")
    expect(failed.score).to be_nil
    expect(failed.diagnostics).to eq("error_class" => "RuntimeError")
    expect(world.node_count).to eq(1)
    expect(emitted("exploration.attempt.failed").size).to eq(1)
  end

  it "rejects trees whose sequence points backward" do
    hash = sample_world.to_h
    hash[:nodes][1][:sequence] = 9

    expect { Agentkit::Exploration::World.from_h(hash) }
      .to raise_error(Agentkit::ConfigurationError, /forward tree|duplicate node sequences/)
  end

  it "requires explicit registration instead of evaluating policy source" do
    described_class.policies.register(:custom, version: "2", policy: StopPolicy.new)
    result = described_class.replay(world: sample_world, policy: :custom, version: "2")
    expect(result.stop_reason).to eq("policy_stop")

    expect do
      described_class.replay(world: sample_world, policy: :missing, version: "1")
    end.to raise_error(Agentkit::ConfigurationError, /not registered/)
  end

  it "binds evaluator name and version to an immutable source manifest" do
    first = ->(_candidate) { { score: 1.0 } }
    second = ->(_candidate) { { score: 2.0 } }
    manifest = described_class.evaluators.register(
      :quality, version: "1", evaluator: first, source_digest: "quality-v1"
    )

    expect(manifest.digest).to start_with("sha256:")
    expect do
      described_class.evaluators.register(
        :quality, version: "1", evaluator: second, source_digest: "changed-source"
      )
    end.to raise_error(Agentkit::ConfigurationError, /without a version bump/)

    world = described_class.run(objective: "registered", generator: ->(**) { {} },
                                evaluator: :quality, evaluator_version: "1", max_rounds: 1)
    expect(world.evaluator_digest).to eq(manifest.digest)
    expect(world.evaluator_manifest.fetch("source_digest")).to eq(manifest.source_digest)
  end

  it "validates registered evaluator output schemas before checkpointing a result" do
    described_class.evaluators.register(
      :invalid_output, version: "1", evaluator: ->(_) { { value: 1 } },
      source_digest: "invalid-output"
    )

    expect do
      described_class.run(objective: "schema", generator: ->(**) { {} },
                          evaluator: :invalid_output, evaluator_version: "1", max_rounds: 1)
    end.to raise_error(Agentkit::SchemaValidationError)

    failed = described_class.store.all(scope: Agentkit::Scope.resolve,
                                       include_incomplete: true).fetch(0)
    expect(failed.status).to eq("failed")
  end

  it "applies the evaluator's declared score normalization before persistence" do
    described_class.evaluators.register(
      :relative_quality, version: "1", evaluator: ->(_) { { score: 12.5 } },
      normalization: :relative_to_baseline, source_digest: "relative-quality"
    )

    world = described_class.run(objective: "normalized", generator: ->(**) { {} },
                                evaluator: :relative_quality, evaluator_version: "1",
                                baseline_score: 10.0, max_rounds: 1)

    expect(world.nodes.last.score).to eq(2.5)
    expect(world.bounds.fetch("baseline_score")).to eq(0.0)
    expect(world.bounds.fetch("evaluator_baseline_score")).to eq(10.0)
  end

  it "refuses to compare histories scored by different evaluator versions" do
    first = sample_world(id: "first")
    second = Agentkit::Exploration::World.from_h(
      sample_world(id: "second").to_h.merge(evaluator_digest: "sha256:other")
    )

    expect do
      described_class.evaluate(policy: DepthPolicy.new, worlds: [first, second])
    end.to raise_error(Agentkit::ConfigurationError, /fixed evaluator digest/)
  end

  it "rejects missing online execution contracts before starting a rollout" do
    expect do
      described_class.run(objective: "x", generator: nil,
                          evaluator: ->(_) { { score: 1 } }, evaluator_id: "eval")
    end.to raise_error(Agentkit::ConfigurationError, /generator/)

    expect do
      described_class.run(objective: "x", generator: ->(**) { {} },
                          evaluator: ->(_) { { score: 1 } }, evaluator_id: "")
    end.to raise_error(Agentkit::ConfigurationError, /evaluator_id/)
  end
end
