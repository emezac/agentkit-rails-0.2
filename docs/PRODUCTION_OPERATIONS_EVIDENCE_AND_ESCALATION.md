# Production Operations Evidence & Escalation — 1.12.0

AgentKit supplies a read-only operations evidence boundary and a durable human
escalation lifecycle. It is **not an autonomous SRE**, an observability collector,
or evidence that a model understands a production system. No LLM, repository,
monitoring vendor or notification provider is contacted automatically.

## What belongs in Rails

| Concern | AgentKit | Host Rails application |
| --- | --- | --- |
| System context | Immutable catalog and digest, validated dependency references | Actual topology, owners, routes, versioned runbooks and SLO definitions |
| What happened | Chronological evidence, scope checks, coverage and freshness | Authorized logs/metrics/traces/configuration connectors, complete query windows, clock synchronization, redaction and retention |
| Recent changes | Exact service/environment/revision binding and SHA-256 of attached diff | Deployment registry, actual deployed revisions (including canary/mixed fleets), authenticated repository reads and complete relevant code context |
| Recommendations | Reference integrity, explicit hypotheses, read-only check contracts, versioned verifier result | Semantic verification, contradictory evidence, uncertainty, independent tests and operational judgement |
| Help | Durable scoped outbox, leases, retries, fallback and ACK state | Human authentication, on-call routing, notification provider, scheduler, independent outage alarm and dashboard |
| Evaluation | Offline fixture replay and contract results | Incident fixtures, blinded holdouts, adjudication and production acceptance thresholds |
| Remediation | **No executor or authorization** | Separately reviewed Capability/DecisionGate workflow, rollout limits, rollback and safety policy |

The catalog constrains metadata; it does not formally prove the real system
matches it. A digest proves content identity, not truth or causality. Host callbacks
are trusted Ruby code, not a sandbox. Never let model output select arbitrary URLs,
files, credentials, routes, tenant identities or executors.

## Setup and catalog

Install engine migrations 024 and 026. `Knowledge::Journal` and
`OperationsEscalationRecord` must share the same database pool. Nothing runs unless
the host instantiates the API and schedules jobs.

```ruby
catalog = Agentkit::Operations::Catalog.new(
  name: "commerce", version: "2026-10-27.1",
  services: {
    "checkout" => {
      owner: "payments-manager", on_call: "payments-primary",
      dependencies: [],
      runbooks: [{ reference: "runbooks/checkout", version: "git:abc123" }],
      slo: { availability_basis_points: 9990 },
      sources: { telemetry: 300, deployments: 300 }
    }
  }
)
```

Service IDs and dependency IDs are strings. All dependencies must exist in the
catalog; cyclic real-system dependencies are allowed. Sources map a host-defined
source name to a positive freshness budget in seconds. Use distinct, tested
primary/fallback routes; the library does not validate provider routing aliases.
SLOs are descriptive metadata, not computed health rules. Runbook bodies and
architecture/code retrieval are the host's responsibility.

Catalogs permit at most 256 services, 16 sources/service, 32 runbooks/service and
1 MiB serialized size. JSON contracts use string keys, integers, strings, booleans,
arrays and objects; convert floating measurements to explicit scaled integers or
decimal strings with units. IDs are immutable idempotency keys, not mutable tickets.

## Build the monitor

```ruby
journal = Agentkit::Knowledge::Journal.new(
  authorize: ->(kind, ctx) { OperationsPolicy.journal?(ctx, kind) }
)
monitor = Agentkit::Operations::Monitor.new(
  catalog: catalog, journal: journal,
  authorize: ->(action, ctx) { OperationsPolicy.allowed?(ctx, action) },
  loader: ->(request, ctx) { ProductionEvidence.read(request, ctx) },
  verifier: ->(recommendation, ctx) { ProductionVerifier.check(recommendation, ctx) },
  verifier_version: "production-review:1", ack_timeout: 900
)
```

`OperationsPolicy`, `ProductionEvidence` and `ProductionVerifier` above are
**host implementation points**, not supplied classes. Default-allow policies in
tests are not production examples. Actions are `capture`, `recommend`, `read`,
`escalate`, `deliver`, `acknowledge`; the Journal separately authorizes kind
`operations`. Deny unknown actions. Workers may deliver; only a validated human
role may acknowledge. Authenticate contexts server-side, never from LLM arguments.
Scope is `Knowledge::Boundary.scope(context)` (tenant + account); all reads and
writes require an explicit principal. Recheck membership/permissions in policies.

## Source loader contract

The loader receives a canonical request with `id`, `service`, `environment`,
`from`, `to`, `catalog_digest`, `source`, `scope`, plus the trusted context.
It must query the complete requested interval with bounded timeouts/pagination,
and return exactly these four keys:

```ruby
{
  scope: Agentkit::Knowledge::Boundary.scope(ctx),
  status: "ok", # or "unavailable"
  observed_at: Time.now.utc.iso8601(6),
  items: [
    { kind: "log", at: "2026-10-27T10:00:00Z",
      reference: "logs/event-42", version: "immutable-event-v1",
      data: { code: "checkout_timeout", trace_id: "trace-9" } }
  ]
}
```

Allowed kinds: `log`, `metric`, `trace`, `deployment`, `configuration`. Each item
requires exactly `kind`, `at`, `reference`, `version`, `data`; data must be an
object. Maximum 500 items/source and 64 KiB/item, with a 16 MiB overall Journal
limit. Do not silently truncate or represent a failed/partial query as `ok` with
an empty array. Summaries must be explicitly identified and versioned by the host.
`observed_at` is when that query completed, not when an old cached result was read.

A deployment item additionally requires these `data` fields:

```ruby
{
  repository: "shop/repo", service: "checkout", environment: "production",
  base_sha: "a" * 40, deployed_sha: "b" * 40,
  diff_reference: "deployments/release-42/diff",
  diff: diff_text, diff_digest: Digest::SHA256.hexdigest(diff_text)
}
```

SHA fields accept full lowercase 40/64-character Git object IDs. The diff is
stored in the dossier and its digest checked; a reference alone is insufficient.
The host must authenticate that this diff belongs to those revisions and to the
actual deployment. The library does not fetch Git or prove that association.
Large diffs must fail as unavailable or use a separately designed reviewed source
contract; do not quietly truncate. Extra data can include deployment IDs, fleet
cohorts and feature flags. Include every relevant deployment for partial rollouts.

Items must be in the incident interval, except deployments may predate its start
to represent the active release. No item may postdate the interval end. Future or
stale source observation timestamps fail coverage. Loader exceptions, malformed
items and oversized items mark that entire source unavailable, recording only
exception class. A wrong/missing scope raises `AccessDenied` and aborts capture.
An unavailable declaration still supplies all four keys (use `items: []`).

```ruby
dossier = monitor.capture(
  id: "incident-42:observation-1", service: "checkout", environment: "production",
  from: "2026-10-27T10:00:00Z", to: "2026-10-27T10:05:00Z", context: ctx
)
```

Capture persists catalog, coverage, timestamped content-addressed evidence and
reasons. Complete capture is `observed`, **not `healthy`**. Any unavailable/stale
required source or missing deployed-change evidence produces `needs_help` and an
escalation atomically with the dossier. Loaders run within the capture transaction;
bound latency and volume. This does not provide a distributed consistent snapshot.
Reuse of an ID replays its original immutable capture; new observations need new
IDs. Conflicting requests raise `IntegrityError`.

## Recommendations and uncertainty

```ruby
ref = dossier.fetch("evidence").first.fetch("id")
result = monitor.recommend(
  id: "review-42:1", incident_id: "incident-42:observation-1", context: ctx,
  observations: [{ text: "Release changed checkout code", evidence_ids: [ref] }],
  hypotheses: [{ text: "Release may contribute to timeouts",
                 supporting_ids: [ref], opposing_ids: [] }],
  checks: [{ text: "Inspect existing latency traces", evidence_ids: [ref], read_only: true }],
  proposed_fix: { description: "Consider rollback", risk: "high",
                  preconditions: ["Human approval and rollout impact review"],
                  rollback: "Restore the previously reviewed release" }
)
```

All three sections require 1..32 entries. References must resolve in this exact
dossier (maximum 64 unique references/field); observations require evidence.
Hypotheses may have no supporting or opposing evidence, so the verifier must reject
overconfident or unsupported conclusions. Checks are declarative, `read_only: true`
only, and are never executed. Preconditions are 1..32 nonempty strings; risk is
`low`, `medium` or `high`.

The verifier receives the canonical proposal plus the dossier and returns exactly
`{ accepted: true/false, reasons: ["..."] }`. An accepting verdict with reasons
still needs help. Semantic verification must be independent of the proposing LLM:
check source meaning, missing contradictory data, temporal validity and uncertainty.
`verified_recommendation` means the contract and the configured host verifier
accepted, **not** that an LLM diagnosis is proven true. Every result permanently
has `authorizes: false` and `causal_proof: false`.

Missing coverage, source expiry before first verification, verifier rejection or
exception creates `needs_help` plus an atomic escalation. Catalog drift requires
recapture; verifier-version drift conflicts with reuse of a recommendation ID.
Replays remain historical receipts, not a fresh operational clearance.

Invalid proposal schemas/references and access denials raise rather than fabricate
a recommendation. Rails must handle these exceptions explicitly: retry bounded
model generation or enqueue an authorized escalation using the stored dossier's
ID/digest and a sanitized reason. Do not rescue them as success. Expose dossiers
with `monitor.fetch(type: "incident"/"recommendation", id: ..., context: ctx)`.

## Durable delivery, acknowledgement and fallback

`monitor.escalations` exposes `enqueue`, `fetch`, `list`, `due`, `deliver` and
`acknowledge`. `list` optionally filters `open`, `acknowledged`, `exhausted`;
`list`/`due` default to 100 rows (maximum 1000). All are tenant/account scoped.
Use these APIs in a host-authorized dashboard; no new public console route exists.

```ruby
# In a host scheduled job, one authenticated tenant/account context at a time.
# Do NOT wrap delivery in an ActiveRecord transaction.
outbox = monitor.escalations
outbox.due(context: worker_ctx).each do |entry|
  outbox.deliver(id: entry.fetch("id"), context: worker_ctx,
    sender: ->(notification, ctx) { NotificationProvider.send_idempotently(notification, ctx) })
end

# In a CSRF-protected authenticated human controller, never an LLM tool:
outbox.acknowledge(id: "incident:incident-42:observation-1",
  reason: "On-call is investigating", context: human_ctx)
```

The sender receives `id`, `incident_id`, `incident_digest`, `reasons`, `target`,
`idempotency_key`, and context. Resolve target aliases server-side; return a
nonempty safe provider receipt string (at most 4096 bytes). Do not put credentials
or full incident payloads into receipts. Provider exceptions store class only.

The default policy is 900s ACK timeout, 60s retry delay, 3 attempts per target and
60s lease. To customize all limits instantiate `Operations::Escalations.new` with
`journal`, `authorize`, `ack_timeout`, `retry_after`, `max_attempts`, `lease_seconds`
(optional injected `clock`). `Monitor` exposes ACK timeout configuration; standalone
enqueue accepts `id`, `incident_id`, 64-hex `incident_digest`, `primary`, `fallback`,
nonempty `reasons` and `context`. Its references are caller-attested; use Monitor
for automatic dossier-bound enqueue. Policy is persisted on creation, not silently
changed by a new worker's defaults; a conflicting enqueue fails.

Claims are locked in PostgreSQL, audited and committed before external IO. Workers
exclude active leases; after a crash, leases expire. Provider calls must have hard
timeouts shorter than the lease. The stable idempotency key is per scoped
escalation and target index. Delivery is **at-least-once**, not exactly-once: the
provider must deduplicate because a process can die after sending but before
persisting its receipt. Superseded completions cannot overwrite a newer claim or
human ACK. Claim, fallback, attempt, exhaustion and ACK records use the Journal.

A receipt leaves the item `open`. Until its deadline, delivery success prevents
resends; failure retries with the same key within the attempt budget. At the ACK
deadline a worker advances to fallback with a new attempt budget and deadline;
after the fallback deadline it marks `exhausted`. Deadlines start at enqueue and
fallback activation, not at provider success. Late human acknowledgement is allowed
and audited. A repeated identical ACK is idempotent; conflicting ACK data fails.
Acknowledgement means a person accepted the escalation, not that the incident is
resolved. Resolution and runbook execution remain separate host workflows.

The host scheduler must run frequently, handle job failures and monitor scheduler/
database/provider availability. A database-backed outbox cannot page anyone during
a total DB outage. An independent watchdog must alarm on missed dispatch heartbeats,
old open items and exhausted items. Never silently recycle exhausted escalations;
an authorized new escalation ID is a separate operational decision.

## Watchtower and replay evaluation

Watchtower catches each detector's failure and emits a critical
`observation_unavailable` finding with source and exception class. An incomplete
scan does not resolve any absent previous findings. A subsequent complete scan
can resolve them. Scan telemetry includes numeric `complete: 0/1`. An entirely
unconfigured optional detector is not evidence that the underlying system is
healthy. Watchtower still checks AgentKit control-plane invariants, not host
application SLOs. It does not automatically dispatch these findings to the new
outbox; Rails must map/rate-limit authorized findings and dispatch them.

`Operations::Replay.evaluate(cases:, runner:)` accepts 1..1000 fixtures with unique
`id`, `input`, `expected_status` (`needs_help`/`verified_recommendation`) and
`required_evidence_ids`. Only `input` reaches the runner. Pass requires matching
status, required observation references and explicit false authorization/causal
flags. Results include fixture/output digests, totals and per-case outcomes.
This is **contract replay, not proof of production competence**. Add human-reviewed
diagnostic correctness, missed-escalation and false-positive measurements in the
host. Preserve blind holdouts and never turn successful replay into automatic
production remediation authority.

Before launch, exercise missing telemetry, stale evidence, wrong deployment SHA,
mixed rollout, tenant isolation, permission revocation, provider timeout, worker
crash, concurrent delivery, lost ACK, exhausted fallback and total database outage.
Start read-only/shadow, validate on historical incidents, then enable human-routed
notifications with independent monitoring.
