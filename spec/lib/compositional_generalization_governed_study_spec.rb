# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/agentkit/harness/compositional_generalization_evaluation"
require_relative "../support/governed_study_fixture"

RSpec.describe "compositional generalization governed studies" do
  include GovernedStudyFixture

  before do
    study_settings
    Agentkit.config.exploration.store = :memory
  end

  def compositional_contract(training_allowed: true, comparison_allowed: true)
    Class.new(Agentkit::Harness::CompositionalGeneralizationEvaluation) do
      attr_reader :training_calls, :comparison_calls

      define_method(:initialize) do
        @training_allowed = training_allowed
        @comparison_allowed = comparison_allowed
        @training_calls = []
        @comparison_calls = []
      end

      def to_h = { "schema_version" => 1, "integration_contract" => true }
      def task_spec(task) = { "task_digest" => task.digest }
      def validate_task_sets!(training_tasks:, holdout_tasks:)
        training_tasks.any? && holdout_tasks.any?
      end

      def normalize_outcome(value, task:)
        data = Agentkit::Harness.stringify_keys(value)
        unless (data.keys - %w[success task_digest]).empty? &&
               (data["task_digest"].nil? || data["task_digest"] == task.digest)
          raise Agentkit::HarnessExperimentError, "invalid compositional outcome task"
        end
        unless [true, false].include?(data["success"])
          raise Agentkit::HarnessExperimentError, "invalid compositional outcome"
        end

        Agentkit::Harness.deep_freeze("success" => data.fetch("success"), "task_digest" => task.digest)
      end

      def summarize(probes, task:)
        successes = probes.count { |probe| probe.dig("compositional_evaluation", "success") }
        Agentkit::Harness.deep_freeze(
          "successes" => successes, "repetitions" => probes.size, "task_digest" => task.digest
        )
      end

      def training_compare(incumbent:, candidate:, tasks:)
        @training_calls << [incumbent, candidate, tasks]
        Agentkit::Harness.deep_freeze(
          "allowed" => @training_allowed, "phase" => "training", "task_count" => tasks.size
        )
      end

      def compare(training_incumbent:, training_candidate:, holdout_incumbent:, holdout_candidate:,
                  training_tasks:, holdout_tasks:)
        @comparison_calls << [training_incumbent, training_candidate, holdout_incumbent,
                              holdout_candidate, training_tasks, holdout_tasks]
        Agentkit::Harness.deep_freeze(
          "allowed" => @comparison_allowed,
          "training_task_count" => training_tasks.size,
          "holdout_task_count" => holdout_tasks.size
        )
      end
    end.new
  end

  def architecture_contract
    Class.new(Agentkit::Harness::ArchitectureEvaluation) do
      def initialize; end
      def to_h = { "schema_version" => 1, "integration_contract" => true }
      def task_spec(task) = { "task_digest" => task.digest }

      def normalize_outcome(value, task:)
        { "success" => value.fetch("success"), "task_digest" => task.digest }.freeze
      end

      def summarize(_probes, task:)
        { "success_rate" => 1.0, "task_digest" => task.digest }.freeze
      end

      def compare(incumbent:, candidate:, tasks:)
        { "allowed" => true, "incumbent" => incumbent.policy_name,
          "candidate" => candidate.policy_name, "task_count" => tasks.size }.freeze
      end
    end.new
  end

  def compositional_study(policy:, architecture: nil)
    build_study(
      compositional_evaluation: policy,
      architecture_evaluation: architecture,
      executor: lambda { |request|
        {
          output_digest: Agentkit::Harness.digest("redacted-output"),
          metrics: {
            quality: request["role"] == "baseline" ? 0.4 : 0.9,
            cost: request["role"] == "baseline" ? 2 : 1,
            latency: request["role"] == "baseline" ? 20 : 10
          },
          compositional_evaluation: { success: request["role"] == "candidate" },
          evaluation: { success: true }
        }
      }
    )
  end

  def real_compositional_task(id, pair:, axis:, stage:, domain:, scale:)
    Agentkit::Harness::ExperimentTask.new(
      id: id, input_reference: "private:#{id}", input_digest: Agentkit::Harness.digest(id),
      model: "fixed-model", output_contract: {}, metadata: {
        compositional_generalization: {
          family: pair, pair_id: pair, axis: axis, stage: stage,
          domain: domain, strategy: "map_reduce", scale: scale,
          critical: false, local_subtasks: true
        }
      }
    )
  end

  def real_task_pairs
    sources = [
      real_compositional_task("rank-short", pair: "ranking", axis: "length",
        stage: "source", domain: "news", scale: 1),
      real_compositional_task("classify-news", pair: "classification", axis: "domain",
        stage: "source", domain: "news", scale: 4),
      real_compositional_task("extract-short", pair: "extraction", axis: "length",
        stage: "source", domain: "legal", scale: 2)
    ]
    targets = [
      real_compositional_task("rank-long", pair: "ranking", axis: "length",
        stage: "target", domain: "news", scale: 8),
      real_compositional_task("classify-legal", pair: "classification", axis: "domain",
        stage: "target", domain: "legal", scale: 4),
      real_compositional_task("extract-long", pair: "extraction", axis: "length",
        stage: "target", domain: "legal", scale: 9)
    ]
    [sources, targets]
  end

  it "keeps compositional outcomes separate and exposes the cross-phase gate only when enabled" do
    policy = compositional_contract
    study = compositional_study(policy: policy)
    selection, holdout = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: holdout)

    expect(selection.selected).to eq("citations")
    expect(result.status).to eq("recommend_review")
    expect(result.holdout.fetch("compositional_evaluation")).to include(
      "allowed" => true, "training_task_count" => 3, "holdout_task_count" => 3
    )
    expect(result.evaluations.first.to_h).to have_key(:compositional_outcomes)
    expect(result.evaluations.first.to_h).not_to have_key(:task_outcomes)
    expect(policy.training_calls).not_to be_empty
    expect(policy.training_calls.map { |call| call[1].policy_name }).to all(eq("citations"))
    expect(policy.comparison_calls.size).to eq(1)
    expect(study.digest).not_to eq(build_study.digest)
  end

  it "runs the real evaluator end to end across paired training and holdout tasks" do
    sources, targets = real_task_pairs
    policy = Agentkit::Harness::CompositionalGeneralizationEvaluation.new
    study = build_study(
      training_tasks: sources, holdout_tasks: targets, compositional_evaluation: policy,
      executor: lambda { |request|
        delegated = request["role"] == "candidate"
        {
          output_digest: Agentkit::Harness.digest("redacted-output"),
          metrics: { quality: delegated ? 0.9 : 0.4, cost: delegated ? 1 : 2,
                     latency: delegated ? 10 : 20 },
          compositional_evaluation: {
            success: delegated, subtasks: { correct: delegated ? 9 : 5, total: 10 },
            root: { turns: 2, input_tokens: 100, output_tokens: 20, context_peak_bytes: 800 },
            subagents: { calls: delegated ? 2 : 0, turns: delegated ? 3 : 0,
                         input_tokens: delegated ? 60 : 0, output_tokens: delegated ? 12 : 0,
                         context_peak_bytes: delegated ? 400 : 0 },
            subcalls: delegated ? 2 : 0, limit_exhausted: false,
            delegation_enabled: delegated
          }
        }
      }
    )
    selection, holdout = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: holdout)

    expect(result.status).to eq("recommend_review")
    expect(result.holdout.fetch("compositional_evaluation")).to include(
      "allowed" => true, "pair_count" => 3, "baseline_no_delegation" => true,
      "axes" => { "length" => 2, "domain" => 1 }
    )
    expect(result.evaluations.last.compositional_outcomes.values).to all(
      include("success_rate" => 1.0, "local_accuracy" => 0.9)
    )
  end

  it "rejects mismatched source and target pairs before launching a study" do
    sources, targets = real_task_pairs
    targets[0] = real_compositional_task("rank-wrong", pair: "other-ranking", axis: "length",
      stage: "target", domain: "news", scale: 8)

    expect {
      build_study(
        training_tasks: sources, holdout_tasks: targets,
        compositional_evaluation: Agentkit::Harness::CompositionalGeneralizationEvaluation.new
      )
    }.to raise_error(Agentkit::HarnessExperimentError, /pair ids must match/)
  end

  it "filters candidates at selection with the compositional training report" do
    policy = compositional_contract(training_allowed: false)
    study = compositional_study(policy: policy)
    selection = study.select(training_worlds: study.run_training)

    expect(selection.selected).to eq("baseline")
    expect(policy.training_calls.size).to eq(1)
    expect(policy.comparison_calls).to be_empty
  end

  it "retains a statistically better candidate when the cross-phase gate fails" do
    policy = compositional_contract(comparison_allowed: false)
    study = compositional_study(policy: policy)
    selection, holdout = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: holdout)

    expect(result.comparison.significant).to be(true)
    expect(result.status).to eq("retain")
    expect(result.reason).to eq("compositional_generalization_gate_failed")
    expect(result.holdout.dig("compositional_evaluation", "allowed")).to be(false)
  end

  it "coexists with architecture evaluation without sharing outcome fields" do
    policy = compositional_contract
    study = compositional_study(policy: policy, architecture: architecture_contract)
    selection, holdout = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: holdout)
    evaluation = result.evaluations.first.to_h

    expect(result.status).to eq("recommend_review")
    expect(result.holdout).to include("architecture_evaluation", "compositional_evaluation")
    expect(evaluation).to include(:task_outcomes, :compositional_outcomes)
    expect(evaluation.fetch(:task_outcomes)).not_to equal(evaluation.fetch(:compositional_outcomes))
  end

  it "rechecks the compositional gate at the governance boundary" do
    study = compositional_study(policy: compositional_contract)
    selection, holdout = study_evidence(study)
    result = Marshal.load(Marshal.dump(study.recommend(selection: selection, holdout_worlds: holdout)))
    result.holdout.fetch("compositional_evaluation")["allowed"] = false

    expect {
      Agentkit::Exploration::Governance.submit!(
        target: "support", recommendation: result,
        scope: Agentkit::Scope.resolve(context: study.context)
      )
    }.to raise_error(Agentkit::ConfigurationError, /compositional generalization evaluation/)
  end

  it "does not allow an opted-in recommendation to omit its compositional report" do
    study = compositional_study(policy: compositional_contract)
    selection, holdout = study_evidence(study)
    result = Marshal.load(Marshal.dump(study.recommend(selection: selection, holdout_worlds: holdout)))
    result.holdout.delete("compositional_evaluation")

    expect {
      Agentkit::Exploration::Governance.submit!(
        target: "support", recommendation: result,
        scope: Agentkit::Scope.resolve(context: study.context)
      )
    }.to raise_error(Agentkit::ConfigurationError, /compositional generalization evaluation/)
  end

  it "does not add compositional identity, payload or evaluation fields to legacy studies" do
    first = build_study
    second = build_study
    selection, holdout = study_evidence(first)
    result = first.recommend(selection: selection, holdout_worlds: holdout)

    expect(first.digest).to eq(second.digest)
    expect(result.holdout).not_to have_key("compositional_evaluation")
    expect(result.evaluations.first.to_h).not_to have_key(:compositional_outcomes)
    expect(result.holdout_evaluations.first.to_h).not_to have_key(:compositional_outcomes)
  end

  it "rejects values that do not implement the compositional evaluation contract" do
    expect { build_study(compositional_evaluation: Object.new) }
      .to raise_error(Agentkit::HarnessExperimentError, /CompositionalGeneralizationEvaluation contract/)
  end
end
