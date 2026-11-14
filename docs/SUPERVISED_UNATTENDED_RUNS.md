# Supervised Unattended Runs — 1.14.0

`Harness::UnattendedRun` is a durable coordinator for bounded work, not a shell
runner, scheduler, sandbox or permission grant. It reuses `Harness::Goal`,
`VerificationGate`, `Knowledge::Journal` and `Operations::Escalations`. The model's
answer never completes a run by itself. Every snapshot says `authorizes: false`.

## Responsibilities

| AgentKit | Rails host / executor |
| --- | --- |
| Scoped immutable contract, run identity and absolute deadline | Approve objective, budgets, repositories and allowed resources before start |
| Reserved cost/tokens and work-attempt limit | Enforce per-call hard caps, actual provider accounting, organization-wide quotas |
| Role-bound leases and transactional admission | Deduplicate launches, isolate processes, kill process trees at timeout and reconcile crashes |
| Exact artifact and gate-result matching | Independently observe actual bytes, run checks, protect the verifier/configuration |
| Structured failure signatures and progress comparison | Define semantic failure codes and useful progress metrics; classify infrastructure failures |
| Durable receipts and atomic escalation intent | Source retention/redaction, scheduled polling, notification delivery and independent watchdog |
| Review-ready terminal state | Human diff review, separate approval for PR/push/merge/deployment |

Install migrations 024, 026 and 031. Run, Journal and escalation outbox models must
share a database pool. No provider SDK or external process is required by the core.

## Trusted control-plane identities

Construct the coordinator with a Journal, an Operations escalation outbox,
`authorize(action, context)` and optionally an injected UTC clock. Actions are
`start`, `work`, `verify`, `read`, `read_history`, `expire`, `cancel`.

The authorizer must deny unknown actions and enforce roles. Journal authorization
must allow kind `unattended` for these trusted identities. The outbox has its own
authorizer and Journal policy for `operations`/`escalate`; grant enqueue to the
trusted coordinators so terminal transitions can commit with escalation intent.
Do not expose these credentials or receipt-writing APIs to the model's tools.

`work` and `verify` identify trusted host wrappers, not arbitrary model-provided
actor names. The same principal cannot verify a run in which it has worked. This
check alone does not establish independence: separate the verifier's process,
permissions, tests and credentials from the editing worker. The role callback
receives action/context, not the complete proposed contract: validate resource
access and per-user budget limits in the trusted host before calling `start`.

All operations are tenant/account scoped through `Knowledge::Boundary.scope`.
`read_history` permits retained worker statements and diagnostics; restrict it and
redact secrets before reporting them. Generic state reads never expose lease tokens.

## Contract

```ruby
h = Agentkit::Harness
goal = h::Goal.new(
  id: "checkout-fix", objective: "Correct checkout rounding",
  criteria: [{ id: "tests", description: "Independent acceptance tests pass" }],
  protected_resources: ["tests/", "ci/"], max_steps: 6
)
gate = h::VerificationGate.new(id: "tests", description: "Checkout acceptance")

run = h::UnattendedRun.new(journal: journal, authorize: run_policy,
  escalations: operations_outbox)
run.start(
  id: "checkout-night-42", goal: goal, gates: [gate], artifact: initial_artifact,
  allowed_resources: ["src/"], protected_resources: ["tests/", "ci/"],
  executor_version: "isolated-runner:3", baseline_green: "no_work",
  limits: { max_attempts: 6, max_cost_microusd: 3_000_000, max_tokens: 200_000,
    run_seconds: 2700, call_seconds: 180, cost_per_call_microusd: 250_000,
    tokens_per_call: 16_000, stall_limit: 2 },
  primary: "engineering-on-call", fallback: "engineering-manager", context: operator_ctx
)
```

All limit fields are required positive integers. Per-call ceilings cannot exceed
run ceilings; call duration cannot exceed run duration. Attempts cannot exceed 1000
or the Goal's `max_steps`. The run cannot omit the Goal's protected resources.
There must be 1..16 distinct required `VerificationGate` objects and nonempty
allowed/protected resource lists (maximum 128 entries each). The full contract
requires gates with IDs matching every required Goal criterion/constraint.
Duplicate resource entries and exact allowed/protected overlap are rejected;
the host must detect overlaps between glob/path patterns. The full contract
is capped at 256 KiB. IDs are nonempty strings up to 128 bytes, other text 4096 bytes.
Contracts use JSON integers, not floating point; one dollar is 1,000,000 microusd.

`artifact` has exactly `commit_sha`, `configuration_digest`, `dependencies_digest`,
`protected_digest`, `reference`, `digest`. Use a full Git SHA-1/SHA-256 commit ID.
All four public digest fields use Harness's `sha256:<64 lowercase hex>` format.
The host supplies digests from authoritative artifact, environment and protected
manifest bytes, not an LLM's assertion. Journal/Operations internal digests use
their existing unprefixed format and are computed internally.

Configuration, dependency and protected-resource digests are fixed for a run.
Dependency/configuration changes require a newly authorized contract, not relaxed
verification. Resource lists are declarative: they do not install filesystem
restrictions, interpret glob patterns or prevent shell escapes. Enforce them in
the executor. `executor_version` identifies the host deployment; the coordinator
does not attest its implementation.

Reusing a run ID with identical input returns current state without resetting
time, attempts or budget. Different input conflicts. A new run ID is a separate
operator-approved run; this feature does not impose quotas across multiple runs.
`contract(id:, context:)` retrieves the immutable contract for worker reconstruction.

## Phase protocol

1. Start in `awaiting_verification` for a baseline check.
2. Claim a verifier lease, run independent checks and report results.
3. A failed baseline becomes `ready`; a green baseline defaults to `no_work`.
4. Claim a worker lease, execute bounded work, then report its artifact and usage.
5. Claim a fresh verifier lease for that artifact. Passing gates yields `verified`;
   failures can allow another bounded attempt or stop for human attention.

`baseline_green: "continue"` explicitly permits tasks whose baseline is already
green. Define acceptance criteria that can actually establish the new objective;
re-running unrelated green tests does not prove a feature was implemented.

```ruby
grant = run.claim(id: run_id, role: "worker", request_id: job_id, context: worker_ctx)
lease = grant.fetch("lease")
return unless lease # busy, wrong admission horizon or terminal; do not execute

# HOST IMPLEMENTATION: invoke a fresh isolated worker, not inside a DB transaction.
# Deduplicate by lease token, enforce expires_at and per-call limits externally.
result = IsolatedExecutor.perform_once(lease: lease, contract: run.contract(id: run_id, context: worker_ctx))
run.report_work(id: run_id, token: lease.fetch("token"),
  artifact: result.artifact, worker_claim: result.summary,
  usage: { cost_microusd: result.cost_microusd, tokens: result.tokens },
  context: worker_ctx)
```

`IsolatedExecutor` is a host integration point, not a supplied class. Role must be
`worker` or `verifier`; wrong-phase claims raise. A claim reserves a full per-call
budget atomically and returns a lease with token, role, principal, request ID,
issue time and expiration. A competing request gets no lease. Retrying the same
request ID by the same principal returns the same live lease; reuse by another
role/principal conflicts. Once settled, replay never grants another execution.
`claim` rejects caller-owned ActiveRecord transactions so its reservation commits
before it returns. Dispatch host jobs only after committed creation/report writes.

**The executor must deduplicate the lease token.** Two duplicate deliveries with
the same trusted identity/request ID can both receive that same lease. Admission
is not proof of exactly-once external execution. Run one isolated workspace per
run/attempt, with immutable output snapshots and no production side effects.

Work reports have `artifact`, `worker_claim`, `usage`, and optional `outcome`
(`completed`, `needs_approval`, `policy_violation`). Worker prose is stored only as
an untrusted claim. `completed` moves to verification, never to `verified`.
The host wrapper must measure usage independently of model text.

## Independent verification

```ruby
grant = run.claim(id: run_id, role: "verifier", request_id: check_job_id, context: verifier_ctx)
return unless grant["lease"]

# Host independently inspects the candidate, protected files and environment.
# It executes checks with the remaining lease time and reserved budget.
observed = VerificationExecutor.inspect_and_check(grant, trusted_gate_definitions)
run.report_verification(id: run_id, token: grant["lease"]["token"],
  artifact: observed.artifact, results: observed.results,
  failures: observed.failures, progress_digest: observed.progress_digest,
  usage: observed.usage, context: verifier_ctx)
```

`results` are typed `VerificationResult` instances, normally built with
`VerificationGate#record`. Require exactly one result per declared gate. Results
must match gate digest, exact commit, configuration and dependency digests, and
their `checked_at` must fall inside the current lease's observed time window.
The independently observed artifact must exactly match the candidate and fixed
protected manifest. `pending`, missing or stale gates mean
`verification_unavailable`, not a pass. Malformed API inputs raise; the host must
handle the error or allow expiry/escalation, never treat exceptions as success.

The verifier is a trusted host adapter: it must inspect actual immutable bytes,
not copy the worker's manifest or accept "tests pass" from its summary. Protect
test configuration, test discovery, interpreters, dependency environment and CI
definitions, not only files under `tests/`. Report artifact mismatches as observed;
the coordinator records `policy_violation` and escalates. It never restores files
with Git or commits unrelated working-tree changes.

Failure diagnostics are at most 32 objects with exactly `gate_id`, `code`,
`subject`, `expected`, `actual`, all bounded nonempty strings. Every failed gate
must have diagnostics and passed gates must not. The structured signature keeps
meaningful numbers; it does not remove all digits from arbitrary logs.
The verifier supplies `progress_digest` (Harness format) over declared measurable
progress, not merely a new Git SHA or a claimed plan. Repeated identical failures
with unchanged progress increment a streak; `stall_limit` consecutive non-progress
post-work checks stop the run. New failure/progress resets the streak; max attempts
still bounds oscillation. Infrastructure failures should report unavailable/pending,
not be disguised as new code failures to keep the loop alive.

## Budgets, deadlines and recovery

Every claim, including baseline and post-work verification, reserves
`cost_per_call_microusd` and `tokens_per_call`. Admission requires room for the full
reservation. Known actual usage refunds the unused portion; measured overruns are
recorded in full and stop as `budget_exhausted`. Cost/tokens must be nonnegative
integers. `usage: nil` preserves the reservation, marks usage incomplete and stops
as `needs_approval`. Never substitute zero when provider output cannot be parsed.

Snapshots' `charged_*` totals include reservations, not just settled invoices.
`usage_complete` is false while a lease is outstanding or consumption is unknown.
Report replay is idempotent; altered replay conflicts. Run deadlines are absolute
and persisted; process restart never resets them. Work attempts count on admission,
including crashes. Verifier calls also consume budget but not a work attempt.

Leases fence receipt acceptance; **they do not terminate an OS process**. Configure
the host's job/container supervisor to kill the full process tree at `expires_at`,
bound output and network calls, and enforce provider request caps. Ruby callback
timeouts or elapsed-time checks between attempts are not sufficient isolation.
Financial reservations are admission control, not a guarantee about provider bills.

A scheduled operator lists `due(context:, limit: 100)` (maximum 500, scoped,
read-only, no lease tokens) and calls `expire(id:, context:)` for each result.
An expired live lease becomes
`needs_approval` with execution unknown; reaching the run deadline becomes
`budget_exhausted`. The coordinator never launches a replacement while an old
process may still act. Late receipts are retained as late, without granting success
or refunding uncertain reservations. Human reconciliation must confirm termination,
actual usage and artifacts before authorizing any new run. `cancel(id:, reason:,
context:)` requests the same safe stop; the host must separately terminate jobs.

## Terminal states and delivery

| State | Meaning |
| --- | --- |
| `verified` | Required independent gates passed on the candidate artifact |
| `no_work` | Baseline already passed under the default policy; no fix claimed |
| `stalled` | Repeated structured failure without measured progress |
| `budget_exhausted` | Admission/attempt/time limit, or measured per-call overrun |
| `verification_unavailable` | Required trustworthy gate evidence missing/pending/stale |
| `policy_violation` | Protected boundary or independent artifact mismatch |
| `needs_approval` | Unknown execution/usage, cancellation or explicit request for help |

Every non-success terminal state is recorded atomically with an Operations outbox
entry `unattended:<run-id>` (no immediate external notification). Operations controls
retry/fallback/human acknowledgement. Its `incident_id` references this run and
`incident_digest` the terminal snapshot; it is not an Operations Monitor dossier.
If persistence/escalation enqueue fails, the transition rolls back: retry recording
the same report, not executing the worker again. Monitor delivery and DB health
independently; an unavailable database cannot emit its own durable alert.

Use `fetch` for current state, `history(id:, offset: 0, limit: 50, context:)` for
paginated attempt receipts (maximum 100), and `receipt(id:, token:, context:)` for
one exact receipt. Each receipt separates worker claims, observed verification,
usage and state. Replayed receipts are historical; use `fetch` for current status.
These APIs support a host morning-review screen; no new public console route exists.

Fresh worker contexts should receive the immutable objective, current artifact and
bounded observed failures from history. Label any previous worker claims as
untrusted. Do not promote failed-attempt prose into verified memory or automatically
change safeguards. Use the existing memory review and governed goal-revision paths.

`verified` is not authority to push, merge, deploy, change payments or edit live
business data. Feed reviewed evidence into existing release/Actions/HITL workflows.
Credential isolation, outbound network restrictions and human approval remain
mandatory host concerns. Nothing is scheduled, launched, committed or deployed by
installing this feature.
