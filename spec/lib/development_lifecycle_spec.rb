# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Harness development lifecycle" do
  let(:base_goal) do
    Agentkit::Harness.define(
      id: "release-77",
      objective: "ship a verified release",
      criteria: [
        { id: "tests", description: "the test suite passes" },
        { id: "review", description: "independent review passes" }
      ],
      scope: { include: ["lib/**"], exclude: ["config/credentials.yml.enc"] },
      required_approvals: ["release:publish"],
      required_outputs: ["package"]
    )
  end

  def populated_progress
    progress = Agentkit::Harness.start(base_goal)
    progress.record_evidence(criterion: "tests", verdict: :verified, source: "ci:77", value: "junit")
    progress.record_evidence(criterion: "review", verdict: :verified, source: "review:77", value: "report")
    progress.record_output("package", reference: "artifact:77", value: "gem bytes")
    progress.record_approval("release:publish", actor: "principal:1", evidence_ref: "approval:77")
    progress
  end

  it "requires host authorization and invalidates only changed requirement evidence" do
    progress = populated_progress
    revision = Agentkit::Harness::GoalRevision.propose(
      progress: progress,
      changes: {
        criteria: [
          { id: "tests", description: "tests and mutation checks pass" },
          { id: "review", description: "independent review passes" }
        ]
      },
      reason: "add the release mutation gate",
      proposed_by: "principal:author"
    )

    expect(revision).to be_approval_required
    expect do
      revision.approve!(
        actor: "principal:reviewer", evidence_ref: "approval:revision-77",
        authorize: ->(_request) { false }
      )
    end.to raise_error(Agentkit::PolicyDenied)

    revision.approve!(
      actor: "principal:reviewer", evidence_ref: "approval:revision-77",
      authorize: ->(request) { request["actor"] == "principal:reviewer" }
    )
    result = revision.apply(progress)

    expect(result.progress.goal.objective).to eq(base_goal.objective)
    expect(result.progress.evidence.keys).to eq(["review"])
    expect(result.invalidated_evidence.map { |item| item["criterion_id"] }).to eq(["tests"])
    expect(result.invalidated_evidence.first["reason"]).to eq("requirement_changed")
    expect(result.carried_evidence.first["evidence_digest"]).to eq(progress.evidence.fetch("review").digest)
    expect(result.progress.outputs.keys).to eq(["package"])
    expect(result.progress.approvals).to be_empty
    expect(result.invalidated_approvals.map { |item| item["name"] }).to eq(["release:publish"])
    expect(progress.evidence.keys).to contain_exactly("tests", "review")
  end

  it "invalidates all prior evidence and artifacts when execution context changes" do
    progress = populated_progress
    revision = Agentkit::Harness::GoalRevision.propose(
      progress: progress,
      changes: { scope: { include: ["lib/**", "app/**"], exclude: [] } },
      reason: "include the Rails adapter",
      proposed_by: "principal:author"
    )
    revision.approve!(
      actor: "principal:reviewer", evidence_ref: "approval:scope-77",
      authorize: -> { true }
    )

    result = revision.apply(progress)

    expect(result.progress.evidence).to be_empty
    expect(result.progress.outputs).to be_empty
    expect(result.invalidated_evidence.map { |item| item["reason"] }.uniq).to eq(["goal_context_changed"])
    expect(result.invalidated_outputs.first["digest"]).to eq(progress.outputs.fetch("package").fetch("digest"))
  end

  it "allows metadata-only revisions without an approval and rejects stale bases" do
    progress = populated_progress
    revision = Agentkit::Harness::GoalRevision.propose(
      progress: progress,
      changes: { metadata: { ticket: "REL-77" } },
      reason: "link the tracking ticket",
      proposed_by: "principal:author"
    )

    expect(revision).not_to be_approval_required
    result = revision.apply(progress)
    expect(result.progress.evidence.keys).to contain_exactly("tests", "review")
    expect(result.progress.approvals.keys).to eq(["release:publish"])

    other = Agentkit::Harness.start(
      Agentkit::Harness.define(
        id: "other", objective: "other goal",
        criteria: [{ id: "done", description: "done" }]
      )
    )
    expect { revision.apply(other) }.to raise_error(Agentkit::HarnessIntegrityError, /base/)
  end

  it "builds a ready release receipt only from matching commit-bound gate evidence" do
    progress = populated_progress
    progress.record_evidence(criterion: "tests", verdict: :verified, source: "ci:77")
    progress.record_evidence(criterion: "review", verdict: :verified, source: "review:77")
    progress.complete!
    commit = "a" * 40
    tests = Agentkit::Harness::VerificationGate.new(
      id: "test-suite", description: "full test suite passes"
    )
    security = Agentkit::Harness::VerificationGate.new(
      id: "security", description: "security scan has no blockers"
    )
    results = [
      tests.record(status: :passed, commit_sha: commit, source: "ci:build-77", value: "junit"),
      security.record(
        status: :passed, commit_sha: commit, source: "scanner:77", value: "sarif",
        configuration_digest: Agentkit::Harness.digest("scanner-v2"),
        dependencies_digest: Agentkit::Harness.digest("lockfile")
      )
    ]

    receipt = Agentkit::Harness::ReleaseCandidateReceipt.build(
      progress: progress,
      commit_sha: commit,
      gates: [tests, security],
      results: results,
      artifact_reference: "artifact:agentkit-77.gem",
      artifact_digest: Agentkit::Harness.digest("gem bytes"),
      deployment_plan_reference: "plan:deploy-77",
      deployment_plan_digest: Agentkit::Harness.digest("deploy plan"),
      rollback_plan_reference: "plan:rollback-77",
      rollback_plan_digest: Agentkit::Harness.digest("rollback plan")
    )

    expect(receipt).to be_ready
    expect(receipt["commit_sha"]).to eq(commit)
    expect(receipt["verification_gates"].map { |item| item["status"] }).to eq(%w[passed passed])
    expect(receipt.digest).to match(/\Asha256:[0-9a-f]{64}\z/)
    expect(receipt.to_h.to_s).not_to include("gem bytes")
  end

  it "marks gate evidence for another commit stale and fails closed" do
    progress = populated_progress
    gate = Agentkit::Harness::VerificationGate.new(
      id: "test-suite", description: "full test suite passes"
    )
    result = gate.record(status: :passed, commit_sha: "b" * 40, source: "ci:old")

    receipt = Agentkit::Harness::ReleaseCandidateReceipt.build(
      progress: progress,
      commit_sha: "c" * 40,
      gates: [gate],
      results: [result],
      artifact_reference: "artifact:77",
      artifact_digest: Agentkit::Harness.digest("artifact"),
      deployment_plan_reference: "plan:deploy",
      deployment_plan_digest: Agentkit::Harness.digest("deploy"),
      rollback_plan_reference: "plan:rollback",
      rollback_plan_digest: Agentkit::Harness.digest("rollback")
    )

    expect(receipt).not_to be_ready
    expect(receipt["verification_gates"].first).to include(
      "status" => "stale", "reason" => "commit_mismatch", "verified_commit_sha" => "b" * 40
    )
  end

  it "refuses to create a release candidate without a verification contract" do
    expect do
      Agentkit::Harness::ReleaseCandidateReceipt.build(
        progress: populated_progress,
        commit_sha: "d" * 40,
        gates: [],
        results: [],
        artifact_reference: "artifact:77",
        artifact_digest: Agentkit::Harness.digest("artifact"),
        deployment_plan_reference: "plan:deploy",
        deployment_plan_digest: Agentkit::Harness.digest("deploy"),
        rollback_plan_reference: "plan:rollback",
        rollback_plan_digest: Agentkit::Harness.digest("rollback")
      )
    end.to raise_error(ArgumentError, /at least one verification gate/)
  end
end
