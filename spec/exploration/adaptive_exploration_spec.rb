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

  before do
    Agentkit.config.exploration.enabled = true
    Agentkit.config.exploration.store = :memory
    Agentkit.config.exploration.max_rounds = 3
    Agentkit.config.exploration.replay_max_rounds = 8
    Agentkit.config.exploration.max_parallelism = 2
    Agentkit.config.exploration.max_nodes = 8
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

  it "includes the incumbent and only emits a reviewed N3 recommendation" do
    worlds = [sample_world(id: "w1"), sample_world(id: "w2", created_at: Time.now.utc + 1)]
    recommendation = described_class.recommend(incumbent: BreadthPolicy.new,
                                                candidates: [DepthPolicy.new], worlds: worlds)

    expect(recommendation.status).to eq("recommend_review")
    expect(recommendation.selected).to eq("DepthPolicy")
    expect(recommendation.level).to eq("n3")
    expect(recommendation.requires_review).to be(true)
    expect(recommendation.auto_promoted).to be(false)
  end

  it "retains the incumbent when history is insufficient" do
    recommendation = described_class.recommend(incumbent: BreadthPolicy.new,
                                                candidates: [DepthPolicy.new], worlds: [sample_world])

    expect(recommendation.status).to eq("retain")
    expect(recommendation.reason).to eq("insufficient_replay_worlds")
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
