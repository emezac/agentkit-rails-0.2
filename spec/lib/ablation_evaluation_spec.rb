# frozen_string_literal: true

require "spec_helper"
require_relative "../support/governed_study_fixture"

RSpec.describe Agentkit::Harness::AblationEvaluation do
  include GovernedStudyFixture

  let(:base_manifest) do
    Agentkit::Harness::Manifest.new(
      id: "support-harness",
      version: "1",
      components: [
        Agentkit::Harness::Component.new(
          name: "core", type: :system_prompt,
          configuration: { text: "Core instructions" }
        ),
        Agentkit::Harness::Component.new(
          name: "pii_guard", type: :guardrail,
          configuration: { redact: true },
          resources: ["security/pii"]
        ),
        Agentkit::Harness::Component.new(
          name: "legacy_hint", type: :tool_guidance,
          configuration: { hint: "Verbose workaround for older model " * 10 }
        ),
        Agentkit::Harness::Component.new(
          name: "extra_middleware", type: :middleware,
          configuration: { retries: 1 }
        )
      ],
      output_contract: { type: "object", required: ["answer"] }
    )
  end

  def ablation_task(index)
    Agentkit::Harness::ExperimentTask.new(
      id: "task-#{index}",
      input_reference: "case:#{index}",
      input_digest: Agentkit::Harness.digest("case:#{index}"),
      model: "frontier-model-v2",
      output_contract: base_manifest.output_contract
    )
  end

  before do
    study_settings
    Agentkit.config.exploration.store = :memory
  end

  it "generates leave-one-out removal revisions while skipping protected components and dependencies" do
    goal = Agentkit::Harness::Goal.new(
      id: "simplify", objective: "Retire obsolete harness rules",
      criteria: [{ id: "quality", description: "Keep quality" }],
      protected_resources: ["security/"]
    )
    ablation = described_class.new(protected_components: ["system_prompt"])
    revisions = ablation.generate_revisions(base: base_manifest, goal: goal)

    expect(revisions.map { |r| r.metadata["removed_component"] })
      .to contain_exactly("tool_guidance:legacy_hint", "middleware:extra_middleware")
    expect(revisions.all? { |r| r.changes.first.operation == "remove" }).to be(true)
  end

  it "recommends non-inferior ablation through GovernedStudy holdout and human review, tracking model decay" do
    old_model_digest = Agentkit::Harness.digest("name" => "legacy-model-v1")
    ablation = described_class.new(
      max_quality_drop: 0.0,
      max_cost_increase: 0.0,
      max_latency_increase: 0.0,
      protected_components: ["system_prompt", "guardrail:pii_guard"],
      previous_model_digest: old_model_digest
    )
    revisions = ablation.generate_revisions(base: base_manifest)

    executor = lambda do |request|
      has_legacy_hint = request.dig("manifest", "components").any? { |c| c["name"] == "legacy_hint" }
      has_middleware = request.dig("manifest", "components").any? { |c| c["name"] == "extra_middleware" }
      if !has_legacy_hint
        # Removing legacy_hint preserves quality while cutting cost & latency
        { output_digest: Agentkit::Harness.digest("out-ablate-hint"),
          metrics: { quality: 0.9, cost: 0.7, latency: 70 } }
      elsif !has_middleware
        # Removing extra_middleware regresses quality
        { output_digest: Agentkit::Harness.digest("out-ablate-mw"),
          metrics: { quality: 0.4, cost: 0.9, latency: 90 } }
      else
        { output_digest: Agentkit::Harness.digest("out-base"),
          metrics: { quality: 0.9, cost: 1.0, latency: 100 } }
      end
    end

    study = Agentkit::Harness::GovernedStudy.new(
      id: "ablation-decay-v1",
      base: base_manifest,
      revisions: revisions,
      training_tasks: (1..3).map { |i| ablation_task(i) },
      holdout_tasks: (4..6).map { |i| ablation_task(i) },
      executor: executor,
      executor_digest: Agentkit::Harness.digest("ablation-runner-v1"),
      ablation_evaluation: ablation
    )

    selection, holdout = study_evidence(study)
    expect(selection.selected).to eq("ablate_tool_guidance_legacy_hint")

    recommendation = study.recommend(selection: selection, holdout_worlds: holdout)
    expect(recommendation.status).to eq("recommend_review")
    expect(recommendation.reason).to eq("non_inferior_harness_ablation")
    expect(recommendation.auto_promoted).to be(false)

    report = recommendation.holdout.fetch("ablation_evaluation")
    expect(report["allowed"]).to be(true)
    expect(report["components_removed"]).to eq(["tool_guidance:legacy_hint"])
    expect(report["context_bytes_saved"]).to be > 0
    expect(report["model_changed"]).to be(true)

    review = study.submit!(target: "harness.support", selection: selection, holdout_worlds: holdout)
    expect(review).to be_pending
    scope = Agentkit::Scope.resolve(context: study.context)
    Agentkit::Exploration::Governance.approve!(review, actor: "human:1", scope: scope)
    expect(study.active_manifest(target: "harness.support").components.map(&:key))
      .not_to include("tool_guidance:legacy_hint")
  end

  it "retains the base manifest when ablation regresses quality on holdout" do
    ablation = described_class.new(max_quality_drop: 0.0, protected_components: ["system_prompt", "guardrail:pii_guard"])
    revisions = ablation.generate_revisions(base: base_manifest).select { |r| r.id == "ablate_tool_guidance_legacy_hint" }

    executor = lambda do |request|
      candidate = request["role"] == "candidate"
      holdout = request["task"]["id"].delete_prefix("task-").to_i > 3
      quality = candidate && holdout ? 0.5 : 0.9
      { output_digest: Agentkit::Harness.digest("out"), metrics: { quality: quality, cost: 0.8, latency: 80 } }
    end

    study = Agentkit::Harness::GovernedStudy.new(
      id: "ablation-regress-v1",
      base: base_manifest,
      revisions: revisions,
      training_tasks: (1..3).map { |i| ablation_task(i) },
      holdout_tasks: (4..6).map { |i| ablation_task(i) },
      executor: executor,
      executor_digest: Agentkit::Harness.digest("ablation-runner-v1"),
      ablation_evaluation: ablation
    )

    selection, holdout = study_evidence(study)
    recommendation = study.recommend(selection: selection, holdout_worlds: holdout)
    expect(recommendation.status).to eq("retain")
    expect(recommendation.reason).to eq("ablation_regression")
    expect(recommendation.holdout.dig("ablation_evaluation", "reasons")).to include("quality_regression")
  end
end
