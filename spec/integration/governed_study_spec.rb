# frozen_string_literal: true
require "rails_helper"
require_relative "../support/governed_study_fixture"

RSpec.describe "Governed harness study persistence", :integration do
  include GovernedStudyFixture

  before { study_settings }

  it "runs queued task worlds, survives registry reload and deduplicates deliveries" do
    Agentkit.config.exploration.execution = :distributed
    account = account!(name: "Harness study")
    context = Agentkit::Context.new(account: account)
    study = build_study(context: context)
    deliveries = []
    Agentkit::Exploration.dispatcher = ->(id, scope) { deliveries << [id, scope] }
    training = study.run_training(distributed: true)
    expect(training.map(&:status)).to eq(["queued"] * 3)
    expect { study.select(training_worlds: training) }.to raise_error(Agentkit::HarnessIntegrityError)

    # New process: no captured generator registry survives.
    Agentkit::Exploration.reset!
    restored = build_study(context: context).register!
    deliveries.each { |id, scope| Agentkit::ExplorationWorldJob.perform_now(id, scope) }
    selection = restored.select(training_worlds: training.map(&:id))
    holdout = restored.run_holdout(selection: selection, distributed: true)
    review = restored.submit!(target: "harness.support", selection: selection, holdout_worlds: holdout)
    expect(Agentkit::ExplorationReviewRecord.find_by!(dossier_id: review.id).status).to eq("pending")
    expect(review.evidence["holdout"]["kind"]).to eq("harness_study")
    scope = Agentkit::Scope.resolve(context: context)
    expect {
      deliveries.each { |id, attrs| Agentkit::ExplorationWorldJob.perform_now(id, attrs) }
    }.not_to change(Agentkit::ExplorationAttemptRecord, :count)
    usage = Agentkit::Exploration::Quota.snapshots(scope: scope)
    expect(usage[:worlds].used).to eq(6)
    expect(usage[:attempts].used).to eq(24)
    Agentkit::Exploration::Governance.approve!(review, actor: "human:operator", scope: scope)
    expect(restored.active_manifest(target: "harness.support").digest).to eq(restored.manifests["citations"].digest)
    Agentkit::Exploration::Governance.rollback!(review, actor: "human:operator", reason: "regression", scope: scope)
    expect(restored.active_manifest(target: "harness.support").digest).to eq(restored.base.digest)
    other = Agentkit::Scope.new(tenant_key: "other")
    expect(Agentkit::Exploration::Governance.find(review.id, scope: other)).to be_nil
  end

  it "blocks stale promotion after another review changed the active baseline" do
    study = build_study
    selection, holdout = study_evidence(study)
    first = study.submit!(target: "harness.support", selection: selection, holdout_worlds: holdout)
    second_study = build_study(id: "different-cycle")
    next_selection, next_holdout = study_evidence(second_study)
    second = second_study.submit!(target: "harness.support", selection: next_selection, holdout_worlds: next_holdout)
    scope = Agentkit::Scope.resolve(context: study.context)
    Agentkit::Exploration::Governance.approve!(first, actor: "human:1", scope: scope)
    expect { Agentkit::Exploration::Governance.approve!(second, actor: "human:2", scope: scope) }
      .to raise_error(Agentkit::DecisionConflict, /incumbent changed/)
    expect(Agentkit::Exploration::Governance.find(second.id, scope: scope)).to be_pending
  end

  it "allows only one of two competing harness promotions", :real_concurrency do
    study = build_study
    selection, holdout = study_evidence(study)
    first = study.submit!(target: "harness.race", selection: selection, holdout_worlds: holdout)
    second_study = build_study(id: "competing-cycle")
    selection2, holdout2 = study_evidence(second_study)
    second = second_study.submit!(target: "harness.race", selection: selection2, holdout_worlds: holdout2)
    scope = Agentkit::Scope.resolve(context: study.context)
    ready, start = Queue.new, Queue.new
    workers = [first, second].map do |review|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          begin
            Agentkit::Exploration::Governance.approve!(review, actor: "human:race", scope: scope)
            :won
          rescue Agentkit::DecisionConflict
            :conflict
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    expect(workers.map(&:value)).to contain_exactly(:won, :conflict)
  end

  it "shows holdout metrics and human actions only behind the console guard" do
    study = build_study(context: Agentkit::Context.new)
    selection, holdout = study_evidence(study)
    study.submit!(target: "harness.support", selection: selection, holdout_worlds: holdout)
    env = -> { Rack::MockRequest.env_for("/agentkit/exploration") }
    expect(Rails.application.call(env.call).first).to eq(404)
    Agentkit.config.console.enabled = true
    expect(Rails.application.call(env.call).first).to eq(403)
    Agentkit.config.console.principal_resolver = -> { "operator:1" }
    Agentkit.config.console.guard = ->(principal) { principal == "operator:1" }
    status, headers, body = Rails.application.call(env.call)
    expect(status).to eq(200)
    expect(headers["cache-control"]).to include("no-store")
    expect(body.each.to_a.join).to include("Governed Self-Improvement", "tareas independientes",
                                          "Pareto entrenamiento", "Aprobar", "Rechazar")
  end
end
