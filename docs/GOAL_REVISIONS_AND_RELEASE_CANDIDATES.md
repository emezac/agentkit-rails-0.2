# Goal revisions and release candidates

AgentKit keeps goal contracts immutable. When requirements change, create a
`GoalRevision`; do not edit a checkpoint payload or silently reinterpret old
evidence. Applying a revision returns new `Progress` plus a redacted record of
evidence, outputs and approvals that became stale.

## Governed revisions

```ruby
revision = Agentkit::Harness::GoalRevision.propose(
  progress: progress,
  changes: {
    criteria: [
      { id: "tests", description: "tests and mutation checks pass" },
      { id: "review", description: "independent review passes" }
    ]
  },
  reason: "strengthen release verification",
  proposed_by: current_principal.id
)

if revision.approval_required?
  revision.approve!(
    actor: reviewer.id,
    evidence_ref: approval.public_id,
    authorize: ->(request) { ReleasePolicy.may_approve_revision?(reviewer, request) }
  )
end

result = revision.apply(progress, context: Agentkit.context)
progress = result.progress
result.invalidated_evidence # digests/reasons, never raw evidence bodies
```

Changes to the objective, requirements, scope, protected resources, approval
policy, required outputs or step budget require a host-authorized approval.
Metadata-only changes do not. Approval callbacks fail closed and receive a
deeply frozen request.

Evidence for an unchanged requirement can be carried into the new progress.
A changed/removed requirement invalidates its evidence. Objective, scope or
protected-resource changes invalidate all prior requirement evidence and
outputs because their execution context is no longer identical. Material
revisions also invalidate earlier approvals. Nothing is deleted: the result and
Audit event retain source and evidence digests with reason codes.

The host should persist/checkpoint the returned progress, not the old object.
It should also retain the revision result when its compliance policy needs a
separate long-term revision ledger.

## Commit-bound verification gates

Gates describe deterministic checks owned and executed by the host. AgentKit
does not execute shell commands or CI jobs.

```ruby
tests = Agentkit::Harness::VerificationGate.new(
  id: "tests",
  description: "the full test suite passes"
)

test_result = tests.record(
  status: :passed,
  commit_sha: git_sha,
  source: "ci:build-918",
  value: junit_xml,
  configuration_digest: Agentkit::Harness.digest(ci_configuration),
  dependencies_digest: Agentkit::Harness.digest(lockfile)
)
```

Only evidence digests and references are retained. A passed or failed result
requires a source. Git SHA-1 and SHA-256 commit identifiers are accepted; short
or symbolic revisions are rejected.

## Release-candidate receipt

```ruby
receipt = Agentkit::Harness::ReleaseCandidateReceipt.build(
  progress: progress,
  revision: revision,
  commit_sha: git_sha,
  gates: [tests],
  results: [test_result],
  artifact_reference: package.url,
  artifact_digest: package.sha256,
  deployment_plan_reference: deployment_plan.url,
  deployment_plan_digest: deployment_plan.sha256,
  rollback_plan_reference: rollback_plan.url,
  rollback_plan_digest: rollback_plan.sha256
)

receipt.ready? # completion + every required gate passed for this exact commit
```

A result for another commit or another gate contract is reported as `stale`.
Missing gate evidence remains `pending`. Readiness also requires the Harness
goal to be complete and artifact, deployment-plan and rollback-plan digests to
be present. The receipt is immutable, redacted and grants no deployment
permission; deployment must still pass the host's Actions/Policy/HITL path.

## Host responsibilities

- Authenticate proposers and reviewers and implement separation of duties.
- Execute CI/security checks outside AgentKit in an isolated environment.
- Build digests from authoritative bytes and retain the referenced artifacts.
- Checkpoint the returned revised progress and retain revision receipts as
  required by policy.
- Re-run gates after any commit, gate contract, configuration or dependency
  change. AgentKit only detects mismatches represented in the supplied data.
- Route deployment through an explicitly authorized, idempotent action.
