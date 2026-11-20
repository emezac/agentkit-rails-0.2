# Execution receipts and readiness

AgentKit can now describe an agent run without persisting its prompt, answer,
tool arguments/results, or retrieved context bodies. These APIs are local and
deterministic; they add no model calls and grant no execution authority.

## Non-mutating inspection

`progress.evaluate` computes the projected completion state without changing
`Progress`. Use `progress.evaluate!` or `progress.complete!` only when the
caller intentionally wants to transition durable state. Harness receipts use
the non-mutating form, so rendering a dashboard or exporting evidence cannot
complete a run.

## Preflight readiness

```ruby
readiness = Agentkit::Harness::ReadinessReport.build(
  progress: progress,
  tools: [lookup_contract],
  budget: execution_budget,
  context_sources: compiled_context,
  verifier: verifier,
  rollback_reference: "git://release/rollback/abc123",
  required: %i[budget context verifier rollback]
)

raise "not ready: #{readiness.blockers.join(', ')}" unless readiness.ready?
```

The report validates goal and step bounds, tool contract identity, budget
limits, context provenance, verifier availability, rollback declaration, and
guards around protected resources. Optional missing controls are warnings;
controls named in `required:` are fail-closed blockers. The report never calls
the supplied verifier or tools.

## Redacted execution receipt

`AgentLoop::Outcome` records the selected model route, loaded skill names,
context-source digests, executed tool-contract digests and attempts, measured
budget/usage, evidence references, and verifier rejection count. Raw data stays
inside the run.

```ruby
receipt = Agentkit::Receipt.execution(
  progress: progress,
  policy_version: "release-policy-7",
  outcome: outcome,
  verification: [
    { gate_id: "ci", status: "passed", evidence_digest: junit_digest }
  ],
  artifact: { reference: "artifact://release/42", digest: artifact_digest },
  rollback: { reference: "git://release/rollback/abc123", digest: rollback_digest },
  human_corrections: 1,
  metadata: { environment: "staging" }
)
```

The receipt is size-bounded, deeply frozen, digest-addressed and explicitly
sets `authorizes: false`. It accepts only allowlisted provenance fields; extra
context or verification bodies are discarded. Artifact and rollback entries
require both a reference and a valid SHA-256 digest.

## Consultative failure-loop findings

The Factory detects repeated `tool.execute` failures and repeated
`harness.verification` rejections. Both findings are N3 policy observations.
No default intervention plan is registered, so AgentKit cannot automatically
increase retries, weaken verification, or alter permissions in response.

