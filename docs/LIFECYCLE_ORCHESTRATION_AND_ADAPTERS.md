# Lifecycle orchestration and host adapters

P2 and P3 extend the governed goal/release contracts without turning AgentKit
into a source-control or deployment client. All APIs are opt-in. They add no
provider SDK, model call, credential store, background process or permission.

## Event-driven replanning

A lifecycle event is bounded declarative data. It may explain why a plan should
change, but it cannot change the goal or grant authority.

```ruby
event = Agentkit::Harness::LifecycleEvent.new(
  id: "github-actions:build-918",
  type: :ci_failed,
  source: "github-actions",
  summary: "integration suite failed",
  signals: { suite: "integration", failed: 2 },
  commit_sha: deployed_commit
)

replanner = Agentkit::Harness::LifecycleReplanner.new(
  name: "release-planner",
  authorize: ->(operation, request, context) {
    LifecyclePolicy.allowed?(operation, request, context)
  },
  planner: ->(request, context) {
    ReleasePlanner.propose(request, context) # rules or a host-controlled model
  }
)

proposal = replanner.propose(
  progress: progress, event: event, context: authenticated_context
)
proposal.to_h.fetch("authorizes") # false
```

The planner response is closed declarative data with `changes`, `reason` and
optional `next_action`/`affected_workstreams`. Unknown fields are rejected. The
request marks event content as untrusted and includes evidence/output digests,
not raw bodies. Provider exceptions are reduced to an error class.

To continue, convert the proposal to the existing governed revision rail:

```ruby
revision = proposal.goal_revision(
  progress: progress, proposed_by: authenticated_context.principal
)
revision.approve!(
  actor: independent_reviewer.id,
  evidence_ref: approval.public_id,
  authorize: ->(request) { GoalRevisionPolicy.approve?(request) }
)
progress = revision.apply(progress, context: authenticated_context).progress
```

The proposal is bound to the exact base-goal digest. A goal change makes the
proposal stale. No event or planner output bypasses the independent revision
approval.

## Lifecycle projection

`LifecycleProjection` is a read-only, model-free view of requirements, outputs,
verification gates, exact blockers, event counts, open replan proposals and
invalidated evidence.

```ruby
projection = Agentkit::Harness::LifecycleProjection.build(
  progress: progress,
  release_candidate: release_receipt,
  events: recent_events,
  proposals: open_replans,
  revisions: applied_revision_results
)
```

The projection does not estimate a critical path or completion date. It reports
only recorded state and returns a digest for cache/audit comparison. The host
owns persistence, access control, pagination and UI rendering.

## Repository adapter

The host callback authenticates with GitHub, GitLab or another provider and
returns a closed snapshot. AgentKit requires a full Git SHA and canonical
digests; it never shells out or reads credentials.

```ruby
repository = Agentkit::Harness::LifecycleAdapters::Repository.new(
  name: "github",
  authorize: ->(operation, request, context) {
    RepositoryPolicy.allowed?(operation, request, context)
  },
  loader: ->(operation, request, context) {
    GitHubEvidence.read(operation, request, context)
  }
)

snapshot = repository.snapshot(
  repository: "org/repo", reference: "main", context: authenticated_context
)
raise "dirty tree" unless snapshot.releasable?

diff = repository.compare(
  repository: "org/repo", base_sha: previous_sha,
  head_sha: snapshot.commit_sha, context: authenticated_context
)
```

## CI adapter

The CI port asks for results only for declared `VerificationGate` contracts and
one exact commit. Returned gate IDs, gate digests and commit SHA must match.

```ruby
ci = Agentkit::Harness::LifecycleAdapters::ContinuousIntegration.new(
  name: "github-actions", authorize: ci_authorizer, loader: ci_loader
)
results = ci.results(
  commit_sha: snapshot.commit_sha, gates: required_gates,
  context: authenticated_context
)
```

Missing results remain missing when the release receipt is built. The adapter
does not infer success from a completed provider job.

## Deployment evidence adapter

The deployment adapter exposes only `plan` and `observe`:

```ruby
deployment = Agentkit::Harness::LifecycleAdapters::Deployment.new(
  name: "heroku", authorize: deployment_reader_policy,
  loader: deployment_evidence_loader
)

plan = deployment.plan(
  commit_sha: snapshot.commit_sha, environment: "staging",
  context: authenticated_context
)

receipt = Agentkit::Harness::ReleaseCandidateReceipt.build(
  progress: progress,
  commit_sha: snapshot.commit_sha,
  gates: required_gates,
  results: results,
  artifact_reference: package.reference,
  artifact_digest: package.digest,
  **plan.receipt_arguments
)
```

There is deliberately no `deploy` method. A host that wants deployment must
register a closed external `Capability` with required idempotency and
reconciliation, expose it in proposal mode and submit it through
`Actions.propose!`. The existing Actions policy, independent approval,
execution receipt and reconciliation boundaries remain mandatory.

## Host responsibilities

- Authenticate provider webhooks and callback identities before creating an
  event or returning adapter evidence.
- Keep credentials entirely outside AgentKit data and logs.
- Authorize every adapter read against tenant, repository and environment.
- Return complete provider evidence with full commit IDs, stable references,
  content digests and trustworthy timestamps.
- Apply provider rate limits, pagination, retries, retention and redaction.
- Persist proposals/events/projections if durable history is required.
- Route every deployment effect through a separately registered governed
  capability; never treat a ready receipt as permission to deploy.
