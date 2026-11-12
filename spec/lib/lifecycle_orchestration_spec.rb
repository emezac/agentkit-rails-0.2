# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Harness lifecycle orchestration" do
  let(:goal) do
    Agentkit::Harness.define(
      id: "delivery-9",
      objective: "deliver a verified change",
      criteria: [{ id: "tests", description: "tests pass" }],
      required_outputs: ["package"],
      required_approvals: ["release:publish"]
    )
  end
  let(:progress) { Agentkit::Harness.start(goal) }
  let(:context) do
    Agentkit::Context.new(tenant_key: "acme", principal: "principal:9")
  end
  let(:event) do
    Agentkit::Harness::LifecycleEvent.new(
      id: "ci:build-9", type: :ci_failed, source: "github-actions",
      summary: "integration tests failed",
      signals: { suite: "integration", failed: 2 }, commit_sha: "a" * 40
    )
  end

  it "creates a declarative replan proposal without mutating or authorizing the goal" do
    planner = lambda do |request, _ctx|
      expect(request).to be_frozen
      expect(request.fetch("event_is_untrusted_data")).to be(true)
      {
        changes: {
          criteria: [
            { id: "tests", description: "tests pass" },
            { id: "integration", description: "integration regression is fixed" }
          ]
        },
        reason: "add explicit integration verification",
        next_action: "diagnose the failed suite",
        affected_workstreams: ["verification"]
      }
    end
    replanner = Agentkit::Harness::LifecycleReplanner.new(
      name: "delivery-planner", planner: planner,
      authorize: ->(operation, _request, _ctx) { operation == "propose" }
    )

    proposal = replanner.propose(progress: progress, event: event, context: context)

    expect(progress.goal.criteria.map(&:id)).to eq(["tests"])
    expect(proposal.to_h["authorizes"]).to be(false)
    expect(proposal.event.digest).to eq(event.digest)
    expect(proposal.digest).to eq(proposal.to_h.fetch("proposal_digest"))
    revision = proposal.goal_revision(progress: progress, proposed_by: "principal:9")
    expect(revision).to be_approval_required
    expect { revision.apply(progress) }.to raise_error(Agentkit::PolicyDenied)
  end

  it "fails closed before invoking a planner when event replanning is denied" do
    called = false
    replanner = Agentkit::Harness::LifecycleReplanner.new(
      name: "delivery-planner",
      planner: ->(*) { called = true },
      authorize: ->(*) { false }
    )

    expect do
      replanner.propose(progress: progress, event: event, context: context)
    end.to raise_error(Agentkit::PolicyDenied)
    expect(called).to be(false)
  end

  it "rejects a replan proposal after the base goal changes" do
    replanner = Agentkit::Harness::LifecycleReplanner.new(
      name: "delivery-planner",
      planner: lambda { |*, **|
        { changes: { metadata: { ticket: "REL-9" } }, reason: "link ticket" }
      },
      authorize: ->(*) { true }
    )
    proposal = replanner.propose(progress: progress, event: event, context: context)
    other_progress = Agentkit::Harness.start(
      Agentkit::Harness.define(
        id: goal.id, objective: goal.objective,
        criteria: goal.criteria, required_outputs: goal.required_outputs,
        required_approvals: goal.required_approvals,
        metadata: { changed: true }
      )
    )

    expect do
      proposal.goal_revision(progress: other_progress, proposed_by: "principal:9")
    end.to raise_error(Agentkit::HarnessIntegrityError, /stale/)
  end

  it "projects exact blockers, event counts and proposed replanning without mutating progress" do
    replanner = Agentkit::Harness::LifecycleReplanner.new(
      name: "delivery-planner",
      planner: ->(*) { { changes: { metadata: { ticket: "REL-9" } }, reason: "link ticket" } },
      authorize: ->(*) { true }
    )
    proposal = replanner.propose(progress: progress, event: event, context: context)
    initial_status = progress.status

    projection = Agentkit::Harness::LifecycleProjection.build(
      progress: progress, events: [event], proposals: [proposal]
    )

    expect(projection["status"]).to eq("replanning")
    expect(projection.dig("phases", "plan")).to eq("replan_proposed")
    expect(projection.fetch("blockers").map { |item| item["item"] }).to contain_exactly(
      "requirement:tests", "output:package", "approval:release:publish"
    )
    expect(projection.dig("events", "ci_failed", "count")).to eq(1)
    expect(progress.status).to eq(initial_status)
  end
end

RSpec.describe Agentkit::Harness::LifecycleAdapters do
  let(:context) do
    Agentkit::Context.new(tenant_key: "acme", principal: "principal:adapter")
  end
  let(:commit) { "b" * 40 }
  let(:now) { Time.now.utc.iso8601(6) }
  let(:authorize) { ->(_operation, _request, ctx) { ctx.principal == "principal:adapter" } }

  it "normalizes repository snapshots and diffs while binding provider identity" do
    loader = lambda do |operation, request, _ctx|
      case operation
      when "repository.snapshot"
        {
          repository: request.fetch("repository"), requested_reference: request.fetch("reference"),
          commit_sha: commit, tree_digest: Agentkit::Harness.digest("tree"),
          dirty: false, observed_at: now
        }
      when "repository.compare"
        {
          repository: request.fetch("repository"), base_sha: request.fetch("base_sha"),
          head_sha: request.fetch("head_sha"), reference: "diff:9",
          digest: Agentkit::Harness.digest("diff"), changed_paths: ["lib/change.rb"],
          observed_at: now
        }
      end
    end
    adapter = described_class::Repository.new(
      name: "github", loader: loader, authorize: authorize
    )

    snapshot = adapter.snapshot(repository: "org/repo", reference: "main", context: context)
    diff = adapter.compare(
      repository: "org/repo", base_sha: "a" * 40, head_sha: commit, context: context
    )

    expect(snapshot).to be_releasable
    expect(snapshot.commit_sha).to eq(commit)
    expect(diff.changed_paths).to eq(["lib/change.rb"])
    expect(diff.head_sha).to eq(commit)
  end

  it "turns authorized CI evidence into commit-bound verification results" do
    gate = Agentkit::Harness::VerificationGate.new(
      id: "tests", description: "test suite passes"
    )
    loader = lambda do |_operation, request, _ctx|
      {
        commit_sha: request.fetch("commit_sha"),
        results: [{
          gate_id: gate.id, gate_digest: gate.digest, status: "passed",
          commit_sha: request.fetch("commit_sha"), source: "ci:9",
          evidence_digest: Agentkit::Harness.digest("junit"),
          configuration_digest: Agentkit::Harness.digest("workflow"),
          dependencies_digest: Agentkit::Harness.digest("lockfile"), checked_at: now
        }]
      }
    end
    adapter = described_class::ContinuousIntegration.new(
      name: "github-actions", loader: loader, authorize: authorize
    )

    result = adapter.results(commit_sha: commit, gates: [gate], context: context).first

    expect(result).to be_passed
    expect(result.commit_sha).to eq(commit)
    expect(result.gate_digest).to eq(gate.digest)
  end

  it "loads deployment and rollback plans plus observations but exposes no deploy operation" do
    loader = lambda do |operation, request, _ctx|
      if operation == "deployment.plan"
        {
          environment: request.fetch("environment"), commit_sha: request.fetch("commit_sha"),
          deployment_reference: "plan:deploy-9", deployment_digest: Agentkit::Harness.digest("deploy"),
          rollback_reference: "plan:rollback-9", rollback_digest: Agentkit::Harness.digest("rollback"),
          observed_at: now
        }
      else
        {
          release_id: request.fetch("release_id"), environment: request.fetch("environment"),
          commit_sha: commit, status: "running", provider_reference: "heroku:release-9",
          evidence_digest: Agentkit::Harness.digest("provider response"), observed_at: now
        }
      end
    end
    adapter = described_class::Deployment.new(
      name: "heroku", loader: loader, authorize: authorize
    )

    plan = adapter.plan(commit_sha: commit, environment: "staging", context: context)
    observation = adapter.observe(release_id: "release-9", environment: "staging", context: context)

    expect(plan.receipt_arguments.fetch(:rollback_plan_reference)).to eq("plan:rollback-9")
    expect(observation.status).to eq("running")
    expect(adapter).not_to respond_to(:deploy)
  end

  it "denies unauthorized reads and redacts provider exception messages" do
    denied = described_class::Repository.new(
      name: "github", loader: ->(*) { raise "must not run" }, authorize: ->(*) { false }
    )
    expect do
      denied.snapshot(repository: "org/repo", reference: "main", context: context)
    end.to raise_error(Agentkit::PolicyDenied)

    failing = described_class::Repository.new(
      name: "github", loader: ->(*) { raise "secret provider token" }, authorize: authorize
    )
    expect do
      failing.snapshot(repository: "org/repo", reference: "main", context: context)
    end.to raise_error(Agentkit::HarnessError, /RuntimeError/) { |error|
      expect(error.message).not_to include("secret provider token")
    }
  end
end
