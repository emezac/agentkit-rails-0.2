# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/agentkit/harness/compositional_generalization_evaluation"

RSpec.describe Agentkit::Harness::CompositionalGeneralizationEvaluation do
  Evaluation = Struct.new(:compositional_outcomes, keyword_init: true)

  def task(id, pair:, axis:, stage:, family:, domain:, scale:, local: true, critical: false)
    Agentkit::Harness::ExperimentTask.new(
      id: id, input_reference: "private:#{id}", input_digest: Agentkit::Harness.digest(id),
      model: "fixed", output_contract: {}, metadata: {
        compositional_generalization: {
          family: family, pair_id: pair, axis: axis, stage: stage,
          domain: domain, strategy: "map_reduce", scale: scale,
          critical: critical, local_subtasks: local
        }
      }
    )
  end

  def paired_tasks
    sources = [
      task("rank-short", pair: "rank-length", axis: "length", stage: "source",
        family: "ranking", domain: "news", scale: 1, critical: true),
      task("classify-news", pair: "classify-domain", axis: "domain", stage: "source",
        family: "classification", domain: "news", scale: 4)
    ]
    targets = [
      task("rank-long", pair: "rank-length", axis: "length", stage: "target",
        family: "ranking", domain: "news", scale: 8, critical: true),
      task("classify-legal", pair: "classify-domain", axis: "domain", stage: "target",
        family: "classification", domain: "legal", scale: 4)
    ]
    [sources, targets]
  end

  def probe(success:, delegated:, correct: 9, total: 10, exhausted: false,
            root_turns: 2, cost: 1.0, latency: 10.0)
    {
      "quality" => success ? 1.0 : 0.0, "cost" => cost, "latency" => latency,
      "compositional_evaluation" => {
        success: success, subtasks: { correct: correct, total: total },
        root: { turns: root_turns, input_tokens: 100, output_tokens: 20, context_peak_bytes: 800 },
        subagents: {
          calls: delegated ? 2 : 0, turns: delegated ? 3 : 0,
          input_tokens: delegated ? 60 : 0, output_tokens: delegated ? 12 : 0,
          context_peak_bytes: delegated ? 400 : 0
        },
        subcalls: delegated ? 3 : 0, limit_exhausted: exhausted,
        delegation_enabled: delegated
      }
    }
  end

  def summary(policy, task, successes:, delegated: 0, correct: 9, total: 10,
              exhausted: 0, repetitions: 4)
    probes = repetitions.times.map do |index|
      probe(success: index < successes, delegated: index < delegated,
        correct: correct, total: total, exhausted: index < exhausted,
        root_turns: 2 + (index % 2), cost: 1 + index, latency: 10 + index)
    end
    policy.summarize(probes, task: task)
  end

  def evaluation(tasks, rows)
    Evaluation.new(compositional_outcomes: tasks.zip(rows).to_h { |item, row| [item.digest, row] })
  end

  it "measures length/domain transfer, local accuracy, family regressions and all execution costs" do
    sources, targets = paired_tasks
    policy = described_class.new(max_transfer_drop: 0.25, minimum_local_accuracy: 0.8)
    report = policy.compare(
      training_tasks: sources, holdout_tasks: targets,
      training_incumbent: evaluation(sources, sources.map { |item| summary(policy, item, successes: 2) }),
      holdout_incumbent: evaluation(targets, targets.map { |item| summary(policy, item, successes: 1) }),
      training_candidate: evaluation(sources, sources.map { |item| summary(policy, item, successes: 4, delegated: 4) }),
      holdout_candidate: evaluation(targets, targets.map { |item| summary(policy, item, successes: 3, delegated: 4) })
    )

    expect(report).to include("allowed" => true, "baseline_no_delegation" => true,
                              "pair_count" => 2, "family_count" => 2, "family_regressions" => 0)
    expect(report["axes"]).to eq("length" => 1, "domain" => 1)
    expect(report["pairs"].map { |row| row["generalization_gap"] }).to all(eq(-0.25))
    expect(report["pairs"].map { |row| row["local_accuracy"] }).to all(eq(0.9))
    expect(report["families"].map { |row| row["success_delta"] }).to all(eq(0.5))
    expect(report.dig("telemetry", "holdout", "candidate", "subagents", "calls")).to eq(2.0)
    expect(report.dig("telemetry", "holdout", "candidate", "root", "input_tokens")).to eq(100.0)
    expect(report.dig("telemetry", "holdout", "candidate", "cost")).to eq(2.5)
    expect { report["pairs"].first["reasons"] << "changed" }.to raise_error(FrozenError)
    expect(report.to_s).not_to include("private:", "secret prompt", "raw output")
  end

  it "fails selection for weak source accuracy, local errors, limit exhaustion, regressions or a delegated baseline" do
    sources, = paired_tasks
    policy = described_class.new(minimum_source_success_rate: 0.5, minimum_local_accuracy: 0.8)
    report = policy.training_compare(
      tasks: sources,
      incumbent: evaluation(sources, sources.map { |item| summary(policy, item, successes: 3, delegated: 1) }),
      candidate: evaluation(sources, sources.map do |item|
        summary(policy, item, successes: 1, delegated: 4, correct: 5, exhausted: 1)
      end)
    )

    expect(report["allowed"]).to be(false)
    expect(report["reasons"]).to include(
      "baseline_delegated", "source_success_below_threshold",
      "local_accuracy_below_threshold", "limit_exhaustion_exceeded",
      "family_regression_limit_exceeded", "critical_task_regressed"
    )
    expect(report["family_regressions"]).to eq(2)
  end

  it "fails holdout for weak transfer, low target lift and target-family regression" do
    sources, targets = paired_tasks
    policy = described_class.new(max_transfer_drop: 0.2, minimum_target_lift: 0.1,
      minimum_local_accuracy: 0.9)
    report = policy.compare(
      training_tasks: sources, holdout_tasks: targets,
      training_incumbent: evaluation(sources, sources.map { |item| summary(policy, item, successes: 3, delegated: 1) }),
      holdout_incumbent: evaluation(targets, targets.map { |item| summary(policy, item, successes: 3) }),
      training_candidate: evaluation(sources, sources.map { |item| summary(policy, item, successes: 4, delegated: 4) }),
      holdout_candidate: evaluation(targets, targets.map do |item|
        summary(policy, item, successes: 1, delegated: 4, correct: 5)
      end)
    )

    expect(report["allowed"]).to be(false)
    expect(report["reasons"]).to include(
      "baseline_delegated", "target_success_below_threshold", "transfer_drop_exceeded",
      "target_lift_below_threshold", "local_accuracy_below_threshold",
      "family_regression_limit_exceeded", "critical_task_regressed"
    )
    expect(report["family_regressions"]).to eq(2)
  end

  it "normalizes redacted outcomes and aggregates root/subagent telemetry per probe" do
    source = paired_tasks.first.first
    policy = described_class.new
    result = policy.summarize([
      probe(success: true, delegated: true, correct: 4, total: 5, root_turns: 1, cost: 1, latency: 10),
      probe(success: false, delegated: true, correct: 3, total: 5, root_turns: 3, cost: 3, latency: 14)
    ], task: source)

    expect(result).to include(
      "success_rate" => 0.5, "successes" => 1, "repetitions" => 2,
      "delegation_rate" => 1.0, "local_subtasks_correct" => 7,
      "local_subtasks_total" => 10, "local_accuracy" => 0.7,
      "subcalls_mean" => 3.0, "limit_exhaustion_rate" => 0.0,
      "quality" => 0.5, "cost" => 2.0, "latency" => 12.0
    )
    expect(result["root"]).to include("turns" => 2.0, "context_peak_bytes" => 800.0)
    expect(result["subagents"]).to include("calls" => 2.0, "input_tokens" => 60.0)
  end

  it "fails closed for malformed pairs, raw fields, counters, summaries and settings" do
    sources, targets = paired_tasks
    policy = described_class.new
    expect { described_class.new(max_transfer_drop: Float::NAN) }
      .to raise_error(Agentkit::HarnessExperimentError)
    expect { described_class.new(max_family_regressions: -1) }
      .to raise_error(Agentkit::HarnessExperimentError)

    raw = probe(success: true, delegated: false).fetch("compositional_evaluation").merge(answer: "secret")
    expect { policy.normalize_outcome(raw, task: sources.first) }
      .to raise_error(Agentkit::HarnessExperimentError, /fields do not match/)
    invalid = probe(success: true, delegated: false).fetch("compositional_evaluation")
      .merge(subtasks: { correct: 11, total: 10 })
    expect { policy.normalize_outcome(invalid, task: sources.first) }
      .to raise_error(Agentkit::HarnessExperimentError, /cannot exceed/)

    wrong_target = task("rank-other", pair: "rank-length", axis: "length", stage: "target",
      family: "ranking", domain: "other", scale: 8, critical: true)
    expect { policy.validate_task_sets!(
      training_tasks: [sources.first], holdout_tasks: [wrong_target]
    ) }.to raise_error(Agentkit::HarnessExperimentError, /one domain/)

    malformed = summary(policy, sources.first, successes: 2).merge("success_rate" => 1.0)
    expect { policy.training_compare(
      tasks: [sources.first], incumbent: evaluation([sources.first], [malformed]),
      candidate: evaluation([sources.first], [malformed])
    ) }.to raise_error(Agentkit::HarnessIntegrityError, /rates do not match/)
    expect(targets).not_to be_empty
  end

  it "serializes an immutable policy without any task or outcome data" do
    policy = described_class.new(
      minimum_source_success_rate: 0.6, minimum_target_success_rate: 0.55,
      minimum_local_accuracy: 0.75, max_transfer_drop: 0.3,
      minimum_target_lift: 0.05, max_family_regressions: nil,
      maximum_limit_exhaustion_rate: 0.1, require_no_delegation_baseline: false
    )
    expect(policy.to_h).to eq(
      "schema_version" => 1, "minimum_source_success_rate" => 0.6,
      "minimum_target_success_rate" => 0.55, "minimum_local_accuracy" => 0.75,
      "max_transfer_drop" => 0.3, "minimum_target_lift" => 0.05,
      "max_family_regressions" => nil, "maximum_limit_exhaustion_rate" => 0.1,
      "require_no_delegation_baseline" => false
    )
    expect(policy).to be_frozen
  end
end
