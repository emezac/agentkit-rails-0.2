# SDD — AgentKit Harness Engineering 1.3.0

Status: implemented

Date: 2026-10-23

## Problem

AgentKit 1.2 gated completion on acceptance criteria and output references, but
several operational rules could still live only in prompt prose: scope,
constraints, protected resources, approvals, source freshness, verifier
independence and recovery behavior. That leaves the model responsible for
remembering controls that the runtime can enforce.

Version 1.3 turns those rules into bounded, inspectable contracts. The design
follows the harness-engineering principle that model capability and system
reliability are separate concerns: the model proposes and reasons; the harness
defines authority, evidence and completion.

## Goals

1. Make task boundaries and approval requirements executable.
2. Give Skills and Capabilities one inspectable tool contract.
3. Separate production from independent verification.
4. Produce a portable, redacted change receipt.
5. Use one failure vocabulary and stop unchanged retry loops.
6. Retrieve context progressively with freshness and provenance.
7. Measure verified outcomes, recovery and harness overhead.

## Non-goals

- Bypassing `Actions`, `Policy` or HITL for domain effects.
- Providing arbitrary filesystem, network or shell access.
- Storing raw artifacts in checkpoints or receipts.
- Letting a verifier repair its own findings.
- Treating latency, cost or token count as proof of task success.

## Components

### Goal contract schema v2

`Harness::Goal` adds:

- `scope.include` and `scope.exclude`;
- independently evidenced `constraints` with `must` / `must_not` kind;
- `protected_resources`;
- `required_approvals` with exact or prefix-wildcard matching.

Required criteria, constraints, outputs and approvals all gate completion.
Approved entries require an evidence reference and digest. Progress also keeps
bounded decisions, issues, next action and lessons. Schema-v1 checkpoints are
verified against their original representation and upgraded only on write.

### ToolContract

Every LLM-facing tool exposes:

- closed input schema and optional output schema;
- preconditions and success-evidence callback;
- risk and effect classification;
- timeout and explicit bounded retry policy;
- deterministic contract and result digests.

The compatibility method `call(**kwargs)` returns the raw result. `invoke`
returns result plus evidence and execution metadata. `internal` and `external`
effects refuse direct execution. Capability v2 exposes `tool_contract`; only an
unpermissioned `read_only` capability receives a direct adapter.

### ContextMap

The map indexes source references, topics, freshness windows and expected
digests. A host-owned loader performs I/O under its own authorization rules.
Compilation selects required/always/relevant sources, bounds every source and
the aggregate, rejects required stale/missing sources and labels retrieved
content as untrusted data. Checkpoints store source evidence, not source bodies.

### Verifier

The verifier receives a deeply frozen snapshot containing the goal digest,
requirement descriptions, output references/digests and evidence summaries.
It cannot mutate progress. Applying a returned review is an explicit second
operation.

An Agent-based reviewer must declare a tool allowlist (an empty list is valid),
and every selected tool must be `read_only`. Missing verdicts become
`unresolved`; `accepted: true` is ignored unless every required requirement is
verified.

### RecoveryPolicy

The common taxonomy is:

`timeout`, `rate_limited`, `invalid_arguments`, `missing_context`,
`failed_check`, `permission_denied`, `contradictory_requirements`,
`ambiguous_effect`, `repeated_unchanged`, `transient`, `permanent`, `unknown`.

Classification is separate from action selection. Actions are bounded and may
retry, repair, retrieve, request approval, escalate, reconcile or stop. An
unchanged fingerprint repeated past the threshold stops before another paid
attempt. Ambiguous effects reconcile; they are never blindly retried.

### Receipt and metrics

`Harness::Receipt.build` includes contract/output/evidence digests, verified,
failed, unresolved and missing requirements, risks, approval state, decisions,
lessons and open issues. It excludes raw output and evidence bodies.

`Harness::Metrics` reports:

- completion and first-pass acceptance rates;
- independent review acceptance;
- recovery and repeated-failure rates;
- human review time and interventions;
- unsupported completion claims;
- time to verified completion;
- harness latency and cost overhead.

## Trust boundaries

- Goal text and source references are application-owned contract data.
- Retrieved content is untrusted and cannot redefine instructions.
- A tool schema validates shape, not authorization.
- Capabilities/Actions/Policy/HITL remain the only governed effect path.
- The verifier can reject but cannot mutate artifacts or progress.
- Telemetry is operational; receipts/checkpoints and Audit carry evidence.
- Tenant scope comes from `Agentkit::Context`, never from model output.

## Compatibility and rollout

No database migration is required. Existing Skills retain their keyword-call
surface and default to `read_only`; hosts should annotate mutating tools before
using them with a verifier. Existing 1.2 goals and checkpoints remain valid.

Recommended rollout:

1. Annotate Skill effects and schemas.
2. Add scope/constraints/protected resources to high-value goals.
3. Require approval evidence for external changes.
4. Add a read-only verifier and rejection criteria.
5. Introduce ContextMap sources with realistic freshness windows.
6. Baseline acceptance, recovery, unsupported-claim and overhead metrics.

Verification command: `bundle exec rake verify`.
