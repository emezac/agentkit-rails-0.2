# frozen_string_literal: true
require "spec_helper"
require_relative "../support/architecture_evaluation_fixture"

RSpec.describe Agentkit::Harness::ArchitectureEvaluation do
  include ArchitectureEvaluationFixture

  before do
    study_settings
    Agentkit.config.exploration.store = :memory
    Agentkit.config.memory.store = :memory
    Agentkit.config.memory.level = :log
  end

  it "blocks a statistically improved candidate when one critical holdout repeat fails" do
    study = architecture_study(fail_task: 4, flaky: true, max_regressions: nil)
    selection, worlds = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: worlds)
    expect(result.comparison.significant).to be(true)
    expect(result.status).to eq("retain")
    expect(result.reason).to eq("architecture_gate_failed")
    report = result.holdout.dig("architecture_evaluation", "holdout")
    expect(report).to include("regressions" => 1, "pass_to_fail" => 1, "allowed" => false)
    failed = report.fetch("tasks").find { |task| task["critical_failure"] }
    expect(failed.dig("candidate", "success_rate")).to eq(0.5)
    expect(failed["quality_delta"]).to be > 0
    expect { study.submit!(target: "support", selection: selection, holdout_worlds: worlds) }
      .to raise_error(Agentkit::ConfigurationError, /significant holdout/)
  end

  it "filters broken training candidates and exposes their per-task report" do
    study = architecture_study(fail_task: 1)
    training = study.run_training
    expect(study.select(training_worlds: training).selected).to eq("baseline")
    report = study.training_architecture_report(training_worlds: training).fetch("citations")
    expect(report["critical_failures"].size).to eq(1)
    expect(report["allowed"]).to be(false)
  end

  it "enforces the regression limit independently of critical tasks and quality" do
    study = architecture_study(critical: false, fail_task: 5, max_regressions: 0)
    selection, worlds = study_evidence(study)
    expect(study.recommend(selection: selection, holdout_worlds: worlds).reason).to eq("architecture_gate_failed")
    tolerant = architecture_study(critical: false, fail_task: 5, max_regressions: 1)
    selection, worlds = study_evidence(tolerant)
    expect(tolerant.recommend(selection: selection, holdout_worlds: worlds).status).to eq("recommend_review")
  end

  it "blocks required-check failures even if the grader reports success and regressions are unlimited" do
    study = architecture_study(critical: false, fail_task: 5, failed_check: true, max_regressions: nil)
    selection, worlds = study_evidence(study)
    report = study.recommend(selection: selection, holdout_worlds: worlds).holdout.dig("architecture_evaluation", "holdout")
    expect(report["reasons"]).to include("required_check_failed")
    expect(report["tasks"].find { |row| row["failed_checks"].any? }["failed_checks"]).to eq(["policy"])
    expect(report["allowed"]).to be(false)
  end

  it "requires ordered production-chain coverage separately in holdout" do
    study = architecture_study(missing_chain: true)
    selection, worlds = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: worlds)
    coverage = result.holdout.dig("architecture_evaluation", "holdout", "coverage")
    expect(coverage["missing_chains"]).to eq([["orders", "shipping"]])
    expect(result.reason).to eq("architecture_gate_failed")
  end

  it "rejects missing, string or nonboolean task outcomes and check verdicts" do
    policy = described_class.new
    task = Agentkit::Harness::ExperimentTask.new(id: "t", input_reference: "t",
      input_digest: Agentkit::Harness.digest("t"), model: "fixed", output_contract: {},
      metadata: { architecture: { required_checks: ["policy"] } })
    [{}, { success: "true" }, { success: true, checks: {} },
     { success: true, checks: { policy: 1 } }].each do |value|
      expect { policy.normalize_outcome(value, task: task) }.to raise_error(Agentkit::HarnessExperimentError)
    end
  end

  it "records a blocked report idempotently without exposing artifacts or raw traces" do
    study = architecture_study(fail_task: 4, diagnostics: delegation_report)
    selection, worlds = study_evidence(study)
    report = study.record_architecture_report!(selection: selection, holdout_worlds: worlds)
    expect(report["status"]).to eq("retain")
    expect(report["delegation_diagnostics"]["pairs"].first["decision"]).to eq("merge_candidate")
    expect(report.to_s).not_to include("secret prompt", "secret output", "private artifact", "private:")
    again = study.record_architecture_report!(selection: selection, holdout_worlds: worlds)
    expect(again).to eq(report)
    expect(described_class::Reports.all(context: study.context).size).to eq(1)
    expect(described_class::Reports.all(context: Agentkit::Context.new(tenant_key: "other"))).to be_empty
    expect(described_class::Reports.all(context: Agentkit::Context.new)).to be_empty
    expect { report["status"].replace("approved") }.to raise_error(FrozenError)
  end

  it "fails closed for disabled persistence and altered report snapshots" do
    study = architecture_study
    selection, worlds = study_evidence(study)
    Agentkit.config.memory.level = :off
    expect { study.record_architecture_report!(selection: selection, holdout_worlds: worlds) }
      .to raise_error(Agentkit::HarnessPersistenceError, /disabled/)
    Agentkit.config.memory.level = :log
    study.record_architecture_report!(selection: selection, holdout_worlds: worlds)
    row = Agentkit.with_context(study.context) {
      Agentkit::Memory.all(types: [described_class::Reports::TYPE], ontological: :imagined).first
    }
    altered = Marshal.load(Marshal.dump(row.metadata))
    altered["architecture_report"]["status"] = "approved"
    row.metadata = altered
    expect { described_class::Reports.all(context: study.context) }
      .to raise_error(Agentkit::HarnessIntegrityError)
  end

  it "keeps optional architecture fields out of legacy evaluation identities" do
    study = build_study
    selection, worlds = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: worlds)
    expect(result.holdout).not_to have_key("architecture_evaluation")
    expect(result.evaluations.first.to_h).not_to have_key(:task_outcomes)
    expect { study.training_architecture_report(training_worlds: []) }
      .to raise_error(Agentkit::HarnessExperimentError, /not enabled/)
    expect(build_study.digest).to eq(study.digest)
    expect(architecture_study.digest).not_to eq(study.digest)
  end


  it "reports recovery from baseline failure without counting it as a regression" do
    study = architecture_study(baseline_fail_task: 4)
    selection, worlds = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: worlds)
    report = result.holdout.dig("architecture_evaluation", "holdout")
    expect(report).to include("allowed" => true, "fail_to_pass" => 1, "regressions" => 0)
    expect(result.status).to eq("recommend_review")
  end

  it "records blocked training candidates before any holdout exists" do
    study = architecture_study(fail_task: 1)
    training = study.run_training
    reports = study.record_training_architecture_reports!(training_worlds: training)
    expect(reports.first["status"]).to eq("training_blocked")
    expect(reports.first["phase"]).to eq("training")
    expect(reports.first["selection_digest"]).to start_with("sha256:")
    expect(described_class::Reports.all(context: study.context).size).to eq(1)
  end

  it "rechecks the architecture gate at the governance boundary" do
    study = architecture_study
    selection, worlds = study_evidence(study)
    result = Marshal.load(Marshal.dump(study.recommend(selection: selection, holdout_worlds: worlds)))
    result.holdout["architecture_evaluation"]["holdout"]["allowed"] = false
    expect {
      Agentkit::Exploration::Governance.submit!(target: "support", recommendation: result,
        scope: Agentkit::Scope.resolve(context: study.context))
    }.to raise_error(Agentkit::ConfigurationError, /architecture evaluation/)
  end

  it "rejects invalid policies and cross-scope diagnostics" do
    expect { described_class.new(minimum_success_rate: Float::NAN) }
      .to raise_error(Agentkit::HarnessExperimentError)
    expect { described_class.new(max_regressions: -1) }
      .to raise_error(Agentkit::HarnessExperimentError)
    expect { described_class.new(required_chains: [["<script>"]]) }
      .to raise_error(Agentkit::HarnessExperimentError)
    expect { architecture_study(diagnostics: delegation_report, context: Agentkit::Context.new(tenant_key: "other")) }
      .to raise_error(Agentkit::HarnessIntegrityError, /scope/)
  end
end
