# frozen_string_literal: true
require "spec_helper"
require_relative "../support/governed_study_fixture"

RSpec.describe Agentkit::Harness::GovernedStudy do
  include GovernedStudyFixture

  before do
    study_settings
    Agentkit.config.exploration.store = :memory
  end

  it "executes matched probes, selects on training and tests independent holdout tasks" do
    study = build_study
    selection, holdout = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: holdout)
    expect(selection.selected).to eq("citations")
    expect(result.status).to eq("recommend_review")
    expect(result.comparison.sample_size).to eq(3) # not six repeated probes
    expect(result.comparison.metric).to eq("harness_quality_per_task")
    expect(result.comparison.ci_lower).to be > 0
    expect(result.auto_promoted).to be(false)
    expect(result.holdout["objectives"]).to include("cost" => "minimize")
    expect(holdout.first.to_h.to_s).not_to include("private:")
    expect(study.recommend(selection: selection, holdout_worlds: holdout).comparison).to eq(result.comparison)
  end

  it "promotes only through human review, resolves approved manifests and rolls back" do
    study = build_study
    selection, holdout = study_evidence(study)
    review = study.submit!(target: "harness.support", selection: selection, holdout_worlds: holdout)
    scope = Agentkit::Scope.resolve(context: study.context)
    expect(review).to be_pending
    expect(study.active_manifest(target: "harness.support").digest).to eq(study.base.digest)
    Agentkit::Exploration::Governance.approve!(review, actor: "human:1", scope: scope)
    expect(study.active_manifest(target: "harness.support").digest).to eq(study.manifests["citations"].digest)
    Agentkit::Exploration::Governance.rollback!(review, actor: "human:1", reason: "regression", scope: scope)
    expect(study.active_manifest(target: "harness.support").digest).to eq(study.base.digest)
  end

  it "retains the base on holdout regression and refuses submission" do
    study = build_study(executor: ->(r) {
      candidate = r["role"] == "candidate"
      holdout = r["task"]["id"].delete_prefix("task-").to_i > 3
      { output_digest: Agentkit::Harness.digest("out"),
        metrics: { quality: candidate ? (holdout ? 0.1 : 0.9) : 0.5, cost: 1, latency: 1 } }
    })
    selection, holdout = study_evidence(study)
    expect(study.recommend(selection: selection, holdout_worlds: holdout).status).to eq("retain")
    expect { study.submit!(target: "support", selection: selection, holdout_worlds: holdout) }
      .to raise_error(Agentkit::ConfigurationError, /significant holdout/)
  end

  it "keeps Pareto tradeoffs rather than treating lower cost as lower quality" do
    study = build_study(executor: ->(r) {
      { output_digest: Agentkit::Harness.digest("out"),
        metrics: { quality: r["role"] == "baseline" ? 0.4 : 0.8,
                   cost: r["role"] == "baseline" ? 1 : 2, latency: 1 } }
    })
    selection, holdout = study_evidence(study)
    expect(study.recommend(selection: selection, holdout_worlds: holdout).pareto_frontier)
      .to contain_exactly("baseline", "citations")
  end

  it "does not execute holdout when training retains the base" do
    study = build_study(executor: ->(_) {
      { output_digest: Agentkit::Harness.digest("out"), metrics: { quality: 0.5, cost: 1, latency: 1 } }
    })
    selection = study.select(training_worlds: study.run_training)
    expect(selection.selected).to eq("baseline")
    expect { study.run_holdout(selection: selection) }.to raise_error(Agentkit::HarnessExperimentError, /retained/)
  end

  it "rejects leaked or duplicate tasks and insufficient repetitions before execution" do
    study = build_study
    task = Agentkit::Harness::ExperimentTask.new(id: "same", input_reference: "same",
      input_digest: Agentkit::Harness.digest("same"), model: "fixed-model", output_contract: {})
    expect { build_study(training_tasks: [task] * 3, holdout_tasks: [task] * 3) }
      .to raise_error(Agentkit::HarnessExperimentError, /unique/)
    expect { build_study(repetitions: 1) }.to raise_error(Agentkit::HarnessExperimentError, /at least two/)
    Agentkit.config.exploration.max_rounds = 1
    expect { build_study }.to raise_error(Agentkit::HarnessExperimentError, /limits/)
  end

  it "rejects forged selections and training evidence substituted for holdout" do
    study = build_study
    training = study.run_training
    selection = study.select(training_worlds: training)
    forged = selection.dup
    forged.selected = "baseline"
    expect { study.run_holdout(selection: forged) }.to raise_error(Agentkit::HarnessIntegrityError)
    expect { study.recommend(selection: selection, holdout_worlds: training) }
      .to raise_error(Agentkit::HarnessIntegrityError, /assignments/)
  end

  it "rejects duplicate worlds and evidence from another tenant" do
    study = build_study
    training = study.run_training
    expect { study.select(training_worlds: [training.first] * 3) }
      .to raise_error(Agentkit::HarnessIntegrityError, /one world/)
    other = build_study(context: Agentkit::Context.new(tenant_key: "other"))
    expect { other.select(training_worlds: training) }.to raise_error(Agentkit::HarnessIntegrityError)
  end

  it "fails closed on failed or nonnumeric probes without persisting error text" do
    study = build_study(executor: ->(_) { raise "secret failure body" })
    training = study.run_training
    expect { study.select(training_worlds: training) }.to raise_error(Agentkit::HarnessIntegrityError)
    expect(training.map(&:to_h).to_s).not_to include("secret failure body")
  end

  it "enforces quotas and does not claim partial studies have sufficient evidence" do
    Agentkit.config.exploration.daily_attempt_limit = 1
    study = build_study
    training = study.run_training
    expect { study.select(training_worlds: training) }.to raise_error(Agentkit::HarnessIntegrityError)
  end

  it "refuses distributed execution without durable stores" do
    study = build_study
    Agentkit.config.exploration.execution = :distributed
    expect { study.run_training(distributed: true) }
      .to raise_error(Agentkit::ConfigurationError, /ActiveRecord/)
  end


  it "checks dossier scope again at the governance boundary" do
    study = build_study
    selection, holdout = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: holdout)
    expect {
      Agentkit::Exploration::Governance.submit!(target: "support", recommendation: result,
        scope: Agentkit::Scope.new(tenant_key: "other"))
    }.to raise_error(Agentkit::ConfigurationError, /scope mismatch/)
  end

  it "bounds tasks and persisted evidence" do
    Agentkit.config.harness.max_study_tasks = 5
    expect { build_study }.to raise_error(Agentkit::HarnessExperimentError, /task limit/)
    Agentkit.config.harness.max_study_tasks = 200
    study = build_study
    selection, holdout = study_evidence(study)
    Agentkit.config.harness.max_checkpoint_bytes = 10
    expect { study.submit!(target: "support", selection: selection, holdout_worlds: holdout) }
      .to raise_error(Agentkit::HarnessPersistenceError, /byte limit/)
  end

  it "rejects stale promotion atomically in the memory store" do
    study = build_study
    selection, holdout = study_evidence(study)
    first = study.submit!(target: "support", selection: selection, holdout_worlds: holdout)
    other = build_study(id: "next-cycle")
    selection2, holdout2 = study_evidence(other)
    second = other.submit!(target: "support", selection: selection2, holdout_worlds: holdout2)
    scope = Agentkit::Scope.resolve(context: study.context)
    Agentkit::Exploration::Governance.approve!(first, actor: "human:1", scope: scope)
    expect { Agentkit::Exploration::Governance.approve!(second, actor: "human:2", scope: scope) }
      .to raise_error(Agentkit::DecisionConflict, /incumbent changed/)
  end

  it "applies goal resource protections before invoking any executor" do
    base = build_study.base
    component = Agentkit::Harness::Component.new(name: "planner", type: :system_prompt,
      resources: ["production/database"], configuration: { text: "edit" })
    revision = Agentkit::Harness::Revision.new(id: "unsafe", base_digest: base.digest,
      scope: :invariant, rationale: "test", changes: [
        { id: "edit", operation: :replace, component: component, rationale: "test" }
      ])
    goal = Agentkit::Harness.define(id: "guard", objective: "protect production",
      criteria: ["verified"], protected_resources: ["production/*"])
    expect { build_study(base: base, revisions: [revision], goal: goal) }
      .to raise_error(Agentkit::HarnessCandidateInvalid, /validation/)
  end

  it "rejects unpaired or empty statistical samples" do
    expect {
      Agentkit::Exploration.compare_paired_scores(incumbent_scores: {}, candidate_scores: {},
        history_digest: "history", incumbent_digest: "base", candidate_digest: "new")
    }.to raise_error(Agentkit::ConfigurationError, /paired/)
  end
end
