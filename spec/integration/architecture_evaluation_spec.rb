# frozen_string_literal: true
require "rails_helper"
require_relative "../support/architecture_evaluation_fixture"

RSpec.describe "Architecture evaluation persistence", :integration do
  include ArchitectureEvaluationFixture
  before { study_settings }

  it "persists blocked holdout reports, reloads them and isolates tenants and accounts" do
    account = account!(name: "Architecture")
    context = Agentkit::Context.new(account: account)
    study = architecture_study(context: context, fail_task: 4, flaky: true)
    selection, worlds = study_evidence(study)
    report = study.record_architecture_report!(selection: selection, holdout_worlds: worlds)
    expect(report["status"]).to eq("retain")
    Agentkit::Memory.reset!
    loaded = Agentkit::Harness::ArchitectureEvaluation::Reports.all(context: context)
    expect(loaded).to eq([report])
    expect(loaded.first.dig("architecture_evaluation", "holdout", "pass_to_fail")).to eq(1)
    expect(Agentkit::ExplorationReviewRecord.count).to eq(0)
    different_account = Agentkit::Context.new(tenant_key: context.tenant_key, account: account.id + 1)
    expect(Agentkit::Harness::ArchitectureEvaluation::Reports.all(context: different_account)).to be_empty
    expect(Agentkit::Harness::ArchitectureEvaluation::Reports.all(context: Agentkit::Context.new)).to be_empty
  end

  it "shows blocked training and holdout tasks with diagnostics behind the console guard" do
    context = Agentkit::Context.new
    traces = delegation_traces(tenant_key: "__global__")
    diagnostics = Agentkit::Harness::DelegationDiagnostics.analyze(traces: traces, agents: delegation_catalog, context: context)
    study = architecture_study(context: context, fail_task: 4, diagnostics: diagnostics)
    selection, worlds = study_evidence(study)
    study.record_architecture_report!(selection: selection, holdout_worlds: worlds)
    training_study = architecture_study(context: context, fail_task: 1)
    training_study.record_training_architecture_reports!(training_worlds: training_study.run_training)
    env = -> { Rack::MockRequest.env_for("/agentkit/exploration") }
    expect(Rails.application.call(env.call).first).to eq(404)
    Agentkit.config.console.enabled = true
    expect(Rails.application.call(env.call).first).to eq(403)
    Agentkit.config.console.principal_resolver = -> { "operator:1" }
    Agentkit.config.console.guard = ->(principal) { principal == "operator:1" }
    status, headers, body = Rails.application.call(env.call)
    expect(status).to eq(200)
    expect(headers["cache-control"]).to include("no-store")
    html = body.each.to_a.join
    expect(html).to include("Architecture Evaluation", "training_blocked", "pass_to_fail",
                           "critical", "merge_candidate", "fold_candidate", "Cadenas cubiertas")
    expect(html).not_to include("secret output", "secret prompt", "private:")
  end

  it "retains architecture evidence in a promotable dossier through review and rollback" do
    context = Agentkit::Context.new(account: account!(name: "Promotable architecture"))
    study = architecture_study(context: context)
    selection, worlds = study_evidence(study)
    review = study.submit!(target: "harness.support", selection: selection, holdout_worlds: worlds)
    saved = Agentkit::ExplorationReviewRecord.find_by!(dossier_id: review.id)
    expect(saved.evidence.dig("holdout", "architecture_evaluation", "holdout", "allowed")).to be(true)
    expect(saved.evidence["holdout_evaluations"].first.fetch("task_outcomes").size).to eq(3)
    scope = Agentkit::Scope.resolve(context: context)
    Agentkit::Exploration::Governance.approve!(review, actor: "human:1", scope: scope)
    expect(study.active_manifest(target: "harness.support").digest).to eq(study.manifests["citations"].digest)
    Agentkit::Exploration::Governance.rollback!(review, actor: "human:1", reason: "regression", scope: scope)
    expect(study.active_manifest(target: "harness.support").digest).to eq(study.base.digest)
  end

  it "recovers an opted-in study in another registry before distributed jobs execute" do
    context = Agentkit::Context.new(account: account!(name: "Distributed architecture"))
    Agentkit.config.exploration.execution = :distributed
    pending = []
    Agentkit::Exploration.dispatcher = ->(id, scope) { pending << [id, scope] }
    study = architecture_study(context: context)
    queued = study.run_training(distributed: true)
    Agentkit::Exploration.reset!
    restored = architecture_study(context: context).register!
    expect(restored.digest).to eq(study.digest)
    pending.each { |id, scope| Agentkit::ExplorationWorldJob.perform_now(id, scope) }
    selection = restored.select(training_worlds: queued.map(&:id))
    holdout = restored.run_holdout(selection: selection, distributed: true)
    report = restored.record_architecture_report!(selection: selection, holdout_worlds: holdout)
    expect(report.dig("architecture_evaluation", "holdout", "allowed")).to be(true)
  end
end
