# Upgrading 1.8.0 → 1.9.0

No new migration; migration 024 remains required. BusinessLearning is opt-in.
Journal authorization callbacks must explicitly allow the new `learning` kind
for authorized users. Define current evidence dependency versions and human-review
policy in Rails. Outcome corrections require a new process version, not mutation.
Rollback revokes a learning proposal; the host restores business configuration.
See [Business Learning Loop](docs/BUSINESS_LEARNING_LOOP.md) before integration.

# Upgrading 1.7.0 → 1.8.0

Install and run engine migration 024 before starting 1.8 workers:

```sh
rails agentkit:install:migrations
rails db:migrate
```

The migration adds the knowledge journal and nullable action proposal gate digest.
Existing proposals with no gate remain valid for ungated capabilities. Adding,
removing or changing a gate invalidates pending proposals for that capability;
create a new reviewed proposal with a new idempotency key. Do not switch gated
actions back to older workers that do not enforce their persisted gate binding.

Read [the Rails 1.8 implementation contract](docs/RAILS_EVIDENCE_AND_DECISION_GATES.md).
All adapters are opt-in. Configure scoped relations, read/decision/journal
authorizers, current requester resolution, sources and required claims in the
host. Register the same contract versions on web and worker processes.

Only internal synchronous executors with closed input schemas and required
idempotency support Capability#knowledge_gate. Effects, evidence and receipts
must use the same DB connection; source/journal pool equality is checked. No
external calls, asynchronous flows or agents inside the transaction. For external
effects persist an intent/outbox locally and dispatch with existing reconciliation.

Gate callbacks receive canonical string-keyed data. Gated Capability executors
receive frozen symbol-keyed inputs; returned/replayed output uses string keys.
Knowledge payloads support JSON integers, strings, booleans, null, arrays and
objects (use integer minor units or decimal strings for monetary values).
Ungated Capability introspection and execution remain compatible. Proc executor
keyword detection now correctly forwards declared context/idempotency_key.

1.7 snapshots remain valid. Rails adapters use a scope derived from tenant and
account; rebuild/reimport legacy snapshots through an authorized app adapter when
their arbitrary old scope differs. A decision check with a repeated event_id
returns historical evidence; omit it or choose a new one for fresh evaluation.

The inbox persists pending events and retries local DB consumers. The host owns
job scheduling and event insertion in its business transaction. There is no
automatic callback on application models and no new recurring worker.

# Upgrading 1.6.0 → 1.7.0

Verified Knowledge Core is opt-in through `Agentkit::Knowledge`; no migration or
new runtime dependency. It also supports `require "agentkit/knowledge"` outside
Rails. Existing AgentLoop, Harness, Memory and Actions APIs are unchanged.

Start with [the Rails implementation contract](docs/VERIFIED_KNOWLEDGE_CORE.md).
The host must define the ontology and approved rules, authorize sources and scope,
build time-consistent evidence, and own persistence and transactional actions.
The core validates deductions relative to these inputs; `approved_by` and source
metadata are not authentication. Do not import LLM-produced approval metadata.

The old standalone `TensorLogic` library is not a dependency and is not migrated
automatically. Translate relation indices into explicit per-atom variables with
`Knowledge.var`, add rule versions and provenance, and review the rule semantics.
`not_entailed` means absent from a completed positive closure, not false in the
world. `incomplete` requires abstention or further work; a proven positive can
still be returned with `closure_complete: false`.

Snapshots and results are immutable, in-process data. JSON snapshots can be
reconstructed with `Snapshot.from_json`; applications must authorize imported
scope and authenticate storage. Rebuild snapshots after evidence/rule changes.
No automatic knowledge promotion, distributed ledger, causal estimator, Tensor
backend or Lean verifier is introduced in this release.

# Upgrading 1.5.1 → 1.6.0

No database migration. Progressive Agent Loop is opt-in via Agent#run_loop.
Existing chat/complete/Flow entry points retain their APIs. The core still has
no runtime gem dependencies; ruby_llm >= 1.15 and < 2 is needed for native turns,
while Fake supports deterministic offline turn scripts. RubyLLM and WebMock
were added only to development/test dependencies for real-SDK contract checks.

Add description/trigger/version/owner metadata to Skill definitions. Existing
skills remain valid with empty descriptors. run_loop lists metadata initially;
procedure fragments and context providers load on demand once per run. Inputs
and context providers remain host owned. Skill-level model/schema preferences
do not silently replace the loop's fixed model/final output schema.

Declare direct ToolContract objects through tools:, optional eager_tools:, or
uses_skills. Tools are deferred by default and schemas become callable on the
next turn after search/loading. max_tools bounds active domain tools, excluding
the two control schemas. A skill's entire permitted tool set must fit that bound
to activate. Catalogs reject ambiguous names and contract drift.

authorize and authorize_skill callbacks take (object, context) and must return
true. Root/child class policies and inherited authorizers intersect. Skill denial
also hides its tools unless the host independently supplies them as explicit
contracts. Tools with non-read-only effects still require governed Actions/HITL;
discovery and skill text never authorize direct effects.

AgentTool calls a child class's run_loop, not its legacy #call override. It carries
the same tenant/account/principal, narrower policy and a shared budget subtree.
Use system/skills to describe the delegated procedure. Nested loops cannot
replace inherited budgets. Delegation is synchronous and depth bounded.

schema: accepts the kernel JSON Schema subset or LLM::Schema. verifier: is a
(request, context) callback returning boolean or {accepted:, reasons:}. Both
checks withhold rejected answers after a bounded repair allowance. Check
outcome.answered? before presenting content or treating the task as complete.

ExecutionBudget bounds admitted model calls and observed tokens/cost across
children and nested legacy completions. Usage is charged before schema parsing,
so invalid/repaired responses are counted exactly once. BudgetExceeded propagates
without being converted to a provider error. Legacy LLM.complete with tools is
rejected under ExecutionBudget to prevent opaque SDK tool recursion.

Costs use configured token rates; cached input is included at the standard rate.
Preflight cannot predict actual token usage or invoice amounts. In-flight work
can exceed a remaining token/cost allowance; no further steps run after measured
exhaustion. Failed attempts without usage remain explicitly unmeasured. Cost
limits require input/output prices; disabling the cost cap exposes unpriced
models in the budget snapshot.

A native turn uses one fixed profile/provider and makes one request without SDK
retry or automatic fallback. Stop/refusal/max-token responses never execute their
proposed tools. Signed provider blocks stay in transient conversation state and
are not returned to users or recorded in loop Audit. Unsupported adapter/version
or response shapes fail visibly.

The transcript, catalogs, callbacks and budget are per-process, single-use runtime
state. Context.loop_state is inherited in-process and excluded from Context.to_h.
There is no durable loop resume or distributed shared-budget ledger in 1.6.0.
Existing Flow/job governance remains separate; do not serialize loop callbacks.

# Upgrading 1.5.0 → 1.5.1

Architecture Evaluation is opt-in. No migration is required. Existing studies
without architecture_evaluation/delegation_diagnostics retain their digest,
probe payload and selection evidence format; 1.5.0 checkpoints remain usable.

Pass Harness::ArchitectureEvaluation to GovernedStudy. ExperimentTask metadata
may declare architecture.chain (an ordered identifier list), critical (boolean)
and required_checks (identifier list). Every required chain needs a declared
case in each cohort. No ordering is inferred from an unordered agent set.

Opted-in executors must return evaluation.success and evaluation.checks with
boolean verdicts on every repetition. Missing required check verdicts or malformed
results invalidate probes. Required check failures always block promotion.
A critical task must meet minimum_success_rate (default 1.0). A regression is
any decrease in paired task success rate; max_regressions defaults to zero and
may be nil. Quality deltas remain diagnostic and do not define task completion.

Training selection filters candidates failing these gates. Holdout failures
return retain/architecture_gate_failed even with a significant quality gain.
The governance boundary rechecks architecture gate verdicts before accepting
a promotion recommendation. Human approval and rollback remain explicit.

record_training_architecture_reports! and record_architecture_report! explicitly
persist both passing and blocked reports to Memory; recommend/select alone do
not write reports. The protected exploration console lists these reports by
tenant/account. Snapshots are durable/imagined, non-embedded and digest checked;
a disabled Memory store or oversized report fails visibly. max_checkpoint_bytes
bounds each report/dossier. The history lookup scans scoped Memory records and
is intended for curated evaluation libraries.

DelegationDiagnostics imports scoped peer invocation spans and an explicit agent
catalog. It does not install tracing middleware or alter routing. Define role,
shared context_group and isolation flags accurately. Input bounds: 200 requests,
64 catalog agents, 64 calls per request, 2,000 calls total; reports also obey the
checkpoint byte limit. Global traces must explicitly declare "__global__".

Only fully sequential peer traces yield ordered chain coverage. Nested coordinator
spans must be excluded by the exporter. Unknown cost/token/context counts are
marked incomplete rather than estimated. Reports can be supplied as
delegation_diagnostics: when constructing the study, binding their digest to
the study identity. A migration proposal still requires a fresh governed eval.

# Upgrading 1.4.1 → 1.5.0

GovernedStudy is opt-in. No new migration is required when the distributed
exploration and promotion-governance migrations from 0.9/1.0 are installed.
Active Job workers must register identical study definitions and versioned
executor/judge implementations before processing study worlds.

Use fixed validated revisions and explicit disjoint ExperimentTask cohorts.
Default minimums are five training and five holdout tasks. Repetitions must be
between two and harness.max_probe_repetitions; every task's schedule must fit
exploration.max_rounds and max_nodes. The new harness.max_study_tasks (200)
bounds total tasks. Dossiers use harness.max_checkpoint_bytes.

The executor returns output_digest and finite nonnegative quality/cost/latency
metrics. Raw outputs and error text are not persisted. Declarative manifests
are included in review evidence: do not embed credentials or sensitive input.
The runner/metrics judge version must be reflected in executor_digest.

Selection uses only training; holdout executes only baseline plus the frozen
winner. Shared paired bootstrap now supports per-task harness means without
changing replay evaluation semantics. A nonsignificant holdout returns retain;
submit! rejects it. No promotion is automatic.

Human reviews reuse Exploration::Governance and the protected exploration
dashboard. A harness approval checks the current binding digest atomically
against its evaluated incumbent. Legacy exploration reviews retain their
existing behavior. active_manifest resolves only known validated manifests,
and rollback restores the previous binding (or host baseline if none existed).

Distributed execution is per task, not per individual probe. Keep world IDs
and use existing work/resume/reconciliation for interrupted deliveries.
Re-running a phase starts new worlds; it is not a phase-idempotency API.
Hosts own authentication, durable job delivery, genuinely independent tasks,
fresh holdout cohorts and sandbox enforcement. No claim of cross-study holdout
secrecy, automatic dataset refresh, or executable-code self-modification.

# Upgrading 1.4.0 → 1.4.1

No database migration is required. Experience Library is opt-in and uses the
existing Memory port (in-memory or ActiveRecord), with durable, imagined records.
Validity TTL belongs to the experience, not to Memory retention: expired entries
stop being retrieved immediately, while maintenance records a stale transition
without deleting audit history.

Experiment results now include tenant/account scope. Capture requires an exact
scope match; older manually constructed results without scope must be rerun.
Use at least two matched successful probes per variant and a single validated
change with a helped/hurt attribution referencing baseline and candidate evidence.
Ineligible evidence returns nil (NO_ENTRY), not a reusable lesson.

Activation is explicit. Hosts must authenticate/authorize reviewers and serialize
writes per experience. Hash-linked snapshots detect missing history, tampering
and conflicting transitions; they are not digital signatures or distributed CAS.
Storage size uses harness.max_checkpoint_bytes; retrieval uses existing ContextMap
limits. No live harness, prompt or policy is automatically changed.

# Upgrading 1.3.0 → 1.4.0

No database migration is required. Harness experiments are opt-in and do not
change existing goals, checkpoints, tool policies or exploration bindings.

Represent the harness you want to test as an immutable manifest. Component
configuration must be JSON data and every dependency uses the stable
`type:name` component key:

```ruby
manifest = Agentkit::Harness::Manifest.new(
  id: "support",
  version: "1",
  components: [
    Agentkit::Harness::Component.new(
      name: :planner,
      type: :system_prompt,
      configuration: { text: "Plan, execute, verify." }
    )
  ],
  output_contract: response_schema
)
```

Experiments require four host-owned adapters: proposer, isolated executor,
contrastor and composer. Adapters receive deeply frozen snapshots. The
executor must return `output_reference` plus either `output_digest` or `output`;
when `output` is supplied it is hashed and discarded.

The default experiment limits are:

```ruby
config.harness.max_manifest_components = 64
config.harness.max_manifest_bytes = 128.kilobytes
config.harness.max_component_bytes = 16.kilobytes
config.harness.max_revision_changes = 16
config.harness.max_experiment_candidates = 8
config.harness.max_probe_repetitions = 5
config.harness.max_context_delta_bytes = 32.kilobytes
```

Candidate adoption remains advisory. Consume `result.selected_manifest` in a
separate application-controlled workflow; do not turn the result into a live
binding without the existing holdout and human-promotion gates.

After upgrading, run:

```bash
bundle exec rake verify
```

---

# Upgrading 1.2.0 → 1.3.0

No database migration is required. Existing 1.2 harness checkpoints are
verified using their original digest and upgraded to schema v2 on the next
write.

Existing goals continue to work. For new long-running tasks, move operational
boundaries out of prompt prose and into the contract:

```ruby
goal = Agentkit::Harness.define(
  objective: "publish a release",
  criteria: [{ id: "tests", description: "CI passes" }],
  constraints: [{ id: "no-prod-write", description: "production unchanged", kind: :must_not }],
  scope: { include: ["lib/**"], exclude: ["config/credentials.yml.enc"] },
  protected_resources: ["production/database"],
  required_approvals: ["release:publish"]
)
```

Every required approval must be recorded before completion:

```ruby
progress.record_approval(
  "release:publish", actor: "principal:42", evidence_ref: "approval:991"
)
```

Skill tools remain compatible and default to `effect: :read_only`. Annotate
mutating tools as `:internal` or `:external`; direct calls will then fail and
the operation must move behind Capability/Actions/Policy/HITL. Reviewer agents
used by `Harness::Verifier` must declare an explicit allowlist, including an
empty list when they need no tools.

The new context limits are optional and have bounded defaults:

```ruby
config.harness.max_context_bytes = 8.kilobytes
config.harness.max_context_source_bytes = 4.kilobytes
config.harness.max_context_sources = 24
```

After upgrading, run:

```bash
bundle exec rake verify
```

---

# Upgrading 1.1.0 → 1.2.0

No database migration is required. Harness checkpoints reuse the memory store,
its tenant boundary and the durable retention policy introduced in 1.1.

Existing agents preserve their current tool exposure until a policy is
declared. Add policies first to reviewer or read-only agents, then inspect the
`agent.tools.filtered` telemetry event before rolling them out broadly:

```ruby
class ReleaseReviewer < Agentkit::Agent
  uses_skills :repository, :release_evidence
  allow_tools :read_file, :grep, :fetch_ci_result
  deny_tools :write_file, :shell, :publish
end
```

Policies are monotonic through inheritance: a subclass can narrow an inherited
allowlist and add denied tools, but it cannot accidentally widen the parent.
They govern tools passed through `Agent#chat` / `Agent#complete`; keep external
effects behind Capability/Actions/Policy and sandbox operating-system tools at
the host boundary.

For work spanning calls or workers, declare a stable goal id and checkpoint at
meaningful boundaries. Checkpoint metadata contains goal text, concise
decisions, issues, references and digests, so do not place secrets or artifact
bodies in those fields. `Memory.level = :off` deliberately disables checkpoint
persistence and makes `Harness.checkpoint!` fail closed.

```ruby
config.harness.max_steps = 20
config.harness.max_checkpoint_bytes = 64.kilobytes
config.harness.max_context_bytes = 8.kilobytes
config.harness.checkpoint_retention = :durable
```

Run the normal validation after upgrading:

```bash
rails agentkit:doctor
bundle exec rake verify
```

---

# Upgrading 1.0.0 → 1.1.0

Install and run migration `023_add_memory_lifecycle`. It adds first-class
retention policy, pin and archival timestamps to existing memories. Existing
rows receive `retention_policy: "keep"`; no prior memory is expired or
archived by the migration.

Recall now excludes rows whose `expires_at` is in the past. Configure named
policies before opting writes or memory types into finite retention:

```ruby
config.memory.retention.default_policy = :keep
config.memory.retention.policies = {
  keep: nil,
  ephemeral: 7.days.to_i,
  standard: 90.days.to_i,
  durable: nil
}
config.memory.retention.by_type = { observation: :standard }
```

Preview lifecycle maintenance before applying it. In multi-tenant mode,
`TENANT` is mandatory; `ACCOUNT_ID` can further narrow the scope.

```bash
rails db:migrate
TENANT=your-tenant rails agentkit:memory_maintenance
TENANT=your-tenant DRY_RUN=0 rails agentkit:memory_maintenance
bundle exec rake verify
```

Archival is non-destructive. Pins remain visible to recall after their deadline
and require an audited reason for both pin and unpin operations. Embedding GC
remains a separate operation governed by `config.memory.embedding.gc`.

---

# Upgrading 0.9.0 → 1.0.0

Install and run migration `022_add_exploration_promotion_governance`. It adds
immutable evidence dossiers and one active declarative policy binding per
tenant/account/target. No existing exploration data is rewritten.

Turn a successful 0.9 recommendation into an explicit review:

```ruby
review = Agentkit::Exploration.submit_recommendation!(
  target: "support.search",
  recommendation: recommendation
)

Agentkit::Exploration.approve_recommendation!(
  review,
  actor: "human:operator-42",
  reason: "reviewed evidence and operational risk"
)
```

Approval changes only `Exploration.policy_binding(target:)`. Resolve that
name/version/digest in application-owned code; do not eval dossier content.
The policy registry is deliberately unchanged. Reject and rollback calls need
a non-empty reason. A rollback is allowed only while that review owns the
active binding, so an older decision cannot overwrite a newer one.

Audit must be enabled and writable for submission or any decision. In
ActiveRecord deployments, keep the existing stable audit v2 signing key.
The console review controls use the same fail-closed `console.guard` and
`console.principal_resolver` already required by 0.9.

Optional quota ledger retention is 90 days and maintenance is a dry-run unless
explicitly applied:

```ruby
config.exploration.quota_retention_days = 90
report = Agentkit::Exploration.readiness(scope: scope)
```

```bash
rails db:migrate
TENANT=your-tenant rails agentkit:doctor
TENANT=your-tenant rails agentkit:exploration_maintenance
TENANT=your-tenant DRY_RUN=0 rails agentkit:exploration_maintenance
bundle exec rake verify
```

Maintenance prunes only expired quota usage/reservation rows. Worlds,
attempts, evidence dossiers, bindings and the audit chain are retained.

---

# Upgrading 0.8.0 → 0.9.0

Install and run migration `021_add_distributed_exploration_and_quotas`. It adds
generator provenance, an operations index, and tenant-scoped quota usage and
reservation ledgers. Existing worlds remain replayable; their generator
manifest is intentionally absent because it cannot be reconstructed safely.

Local execution remains the default. To opt into distributed execution:

```ruby
config.exploration.store = :active_record
config.exploration.execution = :distributed
config.exploration.queue = :agentkit_exploration
config.exploration.daily_world_limit = 20
config.exploration.daily_attempt_limit = 200
```

Use a durable Active Job adapter in production. Register every generator,
evaluator and custom policy during worker boot with a stable name and explicit
version. Then use `Exploration.enqueue`; callable-only `Exploration.run` remains
available for local execution but is deliberately not serializable.

Quota limits are UTC daily admission limits. A nil limit is unlimited, zero
disables the resource, and an optional resolver can override either limit:

```ruby
config.exploration.quota_resolver = ->(scope) do
  scope.tenant_key == "account:enterprise" ?
    { daily_world_limit: 100, daily_attempt_limit: 2_000 } : {}
end
```

The 0.9 dashboard is mounted at `/agentkit/exploration` and remains unavailable
unless the existing fail-closed console guard and principal resolver authorize
the request. In 0.9 it is read-only and never renders objective or candidate payloads.

After upgrading, run:

```bash
rails db:migrate
TENANT=your-tenant rails agentkit:doctor
bundle exec rake verify
```

---

# Upgrading 0.7.1 → 0.8.0

No database migration is required. Version 0.8 changes the evidence required
by `Exploration.recommend`: a point estimate over all worlds is no longer
enough for an N3 review recommendation.

Configure a stable holdout assignment and statistical floors:

```ruby
config.exploration.holdout_fraction = 0.2
config.exploration.holdout_seed = ENV.fetch("AGENTKIT_EXPLORATION_HOLDOUT_SEED")
config.exploration.min_training_worlds = 5
config.exploration.min_holdout_worlds = 5
config.exploration.bootstrap_samples = 2_000
config.exploration.confidence_level = 0.95
config.exploration.min_score_improvement = 0.0
config.exploration.pareto_epsilon = 1e-9
```

Do not change `holdout_seed` after accumulating history: doing so reassigns old
worlds and invalidates comparisons with previous recommendation reports. The
returned `assignment_digest`, training digest and holdout digest make the split
reproducible without exposing the seed.

`recommend` now performs these phases:

1. Select non-dominated candidates on training quality, attempts and rounds.
2. Choose one candidate by the configured replay score.
3. Replay only that candidate and the incumbent on holdout.
4. Require holdout coverage, a non-dominated result and a paired bootstrap
   confidence interval above `min_score_improvement`.

Use an explicit frozen benchmark when available:

```ruby
Agentkit::Exploration.recommend(
  incumbent: CurrentPolicy.new,
  candidates: candidate_policies,
  worlds: training_worlds,
  holdout_worlds: frozen_holdout_worlds
)
```

Training and holdout must be disjoint and share one evaluator digest. Existing
callers can continue using `evaluate` for descriptive point estimates and
`compare` for a paired statistical report. Neither method promotes policies.

After upgrading, run:

```bash
TENANT=your-tenant rails agentkit:doctor
bundle exec rake verify
```

---

# Upgrading 0.7.0 → 0.7.1

Install and run migrations `019_harden_agentkit_exploration` and
`020_add_agentkit_exploration_world_leases`. They add resumable checkpoints,
durable attempt/idempotency records, evaluator manifests and exclusive resume
leases. Existing completed worlds remain replayable, and exploration remains
disabled by default.

Recommended production settings:

```ruby
config.exploration.min_replay_coverage = 0.8
config.exploration.attempt_stale_after = 300
config.exploration.resume_lease = 300
```

Prefer the versioned evaluator registry for new rollouts. The callable plus
`evaluator_id` API remains compatible.

```ruby
Agentkit::Exploration.evaluators.register(
  :support_quality,
  version: "4",
  evaluator: SupportEval.method(:score),
  output_schema: {
    type: "object",
    properties: { score: { type: "number" } },
    required: ["score"],
    additionalProperties: false
  },
  normalization: :identity
)

world = Agentkit::Exploration.run(
  objective: "improve support",
  generator: SupportDiscovery.method(:propose),
  evaluator: :support_quality,
  evaluator_version: "4"
)
```

After a process interruption, call `Exploration.resume` with the same policy,
generator and evaluator manifest. A stale claimed attempt becomes
`execution_unknown`; inspect the external system and then call
`reconcile_attempt!` with `pending`, `completed` or `failed`. AgentKit does not
retry an ambiguous effect automatically.

Replay evaluations now expose historical decision coverage. `recommend`
retains the incumbent with reason `insufficient_replay_coverage` when the
configured floor is not met. Promotion remains a separate reviewed N3 action.

After migrating, run:

```bash
rails agentkit:doctor
bundle exec rake verify
```

---

# Upgrading 0.6.0 → 0.7.0

Install and run migration `018_create_agentkit_exploration_worlds`. It adds a
tenant-scoped replay pool; existing agent, Factory and retrieval behavior is
unchanged because adaptive exploration remains disabled by default.

Enable it only after registering a fixed domain evaluator and choosing server
ceilings:

```ruby
config.exploration.enabled = true
config.exploration.max_rounds = 8
config.exploration.replay_max_rounds = 32
config.exploration.max_parallelism = 4
config.exploration.max_nodes = 64
config.exploration.max_policies = 16
config.exploration.default_beta = 0.6
```

`evaluator_id` is provenance, so version it whenever scoring semantics change.
Generators should return candidates; evaluators must return a finite `score`
and may add bounded `diagnostics`, `status`, `failure_class` and `metadata`.
AgentKit stores only objective/artifact digests, not their raw content.

Replay policies see only `View#nodes` for the revealed prefix and
`View#legal_actions`. Register custom policies explicitly:

```ruby
Agentkit::Exploration.policies.register(
  :support_portfolio,
  version: "1",
  policy: SupportPortfolioPolicy.new
)
```

`Exploration.recommend` and `plan_beta` are advisory. Applying a new policy is
a separately reviewed Factory N3 intervention; 0.7.0 has no generated-code
evaluation or automatic policy promotion.

After migrating, run:

```bash
rails agentkit:doctor
bundle exec rake verify
```

---

# Upgrading 0.5.0 → 0.6.0

Install and run migration `017_create_agentkit_graph_snapshots`. It adds graph
snapshot/node/edge tables and provenance fields to existing code symbols. The
migration is additive; existing Wiki, CodeGraph and RAG APIs keep working.

Graph retrieval is opt-in. Build a validated snapshot, then request the new
strategy explicitly:

```ruby
wiki = Agentkit::TeamMemory::Wiki.build_snapshot("EngineeringWiki")

Agentkit::RAG.retrieve(
  "cómo se valida un reembolso",
  corpus_name: "engineering",
  strategy: :hybrid_graph,
  graph: "EngineeringWiki",
  explain: true
)
```

Configure server-side bounds rather than accepting arbitrary values from a
caller:

```ruby
config.team_memory.graph_enabled = true
config.team_memory.graph_allowed_roots = [Rails.root.join("app").to_s]
config.team_memory.graph_max_nodes = 2_000
config.team_memory.graph_max_edges = 10_000
config.team_memory.graph_max_hops = 3
config.team_memory.graph_wall_time_ms = 250
```

Flow annotations are optional but make unsafe topology visible at boot and in
`MyFlow.explain_plan`. A `side_effecting` parallel/map node now requires an
explicit `idempotency_key` annotation.

Run the included labeled evaluation before making graph retrieval a host-level
default. The command reports measured values and refuses to run without a
dataset:

```bash
DATASET=config/graph_retrieval_eval.json bundle exec rake agentkit:graph_eval
bundle exec rake verify
```

The activation viewer is protected by the existing console guard. Publish an
already-computed trace with `TeamMemory::Visualization.publish(result.trace,
context:)` and open `/agentkit/team_memory/activation/:id`. It cannot change
ranking or authorization state.

---

# Upgrading 0.4.1 → 0.5.0

Install and run migration `016_create_agentkit_governed_actions`. It creates
the action proposal/decision/attempt/outbox/outcome tables, audit chain heads,
Watchtower findings and adds audit-v2 columns.

Configure an audit HMAC key before booting with the ActiveRecord audit store:

```ruby
config.audit.active_key_id = ENV.fetch("AGENTKIT_AUDIT_KEY_ID", "primary")
config.audit.signing_keys = {
  config.audit.active_key_id => ENV.fetch("AGENTKIT_AUDIT_KEY")
}
```

Migrate externally visible capabilities to contract v2. `inputs` remains as a
deprecated compatibility surface, but it is not a closed protocol contract.

```ruby
cap.input_schema(type: "object", properties: { id: { type: "integer" } },
                 required: ["id"], additionalProperties: false)
cap.output_schema(type: "object", properties: {}, additionalProperties: false)
cap.effect :internal
cap.required_permission "records.write"
cap.expose :a2a, mode: :propose
```

Exposure is now deny-by-default. Add `cap.expose :a2a` for every intended A2A
skill. Install `agentkit-mcp` separately and add `cap.expose :mcp`; merely
registering a capability never publishes it.

A2A authorization tasks now use ids such as `action:<public_id>`, not HITL
suggestion ids. Approve or reject them through `Agentkit::Actions.decide!` with
an authenticated principal. The requester cannot approve its own action.

External capabilities must require a durable idempotency key and define a
required reconciler. A timeout becomes `execution_unknown`, not `execution_failed`; reconcile it
before retrying so an ambiguous side effect is never repeated blindly.

After migration run:

```bash
rails agentkit:audit_verify TENANT=__global__
rails agentkit:watchtower
bundle exec rake verify
```

---

# Upgrading 0.4.0 → 0.4.1

Install and run migration `015_harden_agentkit_hitl_and_audit`. It adds the
execution lifecycle fields and a partial unique index for durable HITL
idempotency. Historical duplicate keys are preserved under stable `:legacy:`
namespaces instead of being deleted.

Approvals now move through `pending → approved → executing → executed`. Queue
dispatch failures become `execution_failed`; failures after a worker has
claimed the operation become `execution_unknown`. Code that previously tested
for the persisted values `accepted` or `auto_applied` should use
`suggestion.approved?` or the new lifecycle states.

Idempotency keys no longer expire after `hitl.dedupe_window`. Supply a stable
`operation_namespace:` when a key could be reused by independent operations.
Reusing the same tuple with different canonical arguments raises
`Agentkit::IdempotencyConflict`. Rows must be retained for at least as long as
the host promises retry safety; deleting them also deletes that guarantee.

Prompt previews are now disabled by default. Opt in only where the data policy
allows it, and select whether audit storage may fail open:

```ruby
config.audit.prompt_preview_chars = 0
config.audit.failure_mode = :best_effort # or :required
```

The AgentKit console is also disabled by default, including development and
test. Enabling it requires both an authenticated principal and a fail-closed
authorization policy:

```ruby
config.console.enabled = true
config.console.principal_resolver = -> { current_user }
config.console.guard = ->(principal) { principal.admin? }
# Without this optional permission, payloads are recursively redacted.
config.console.payload_guard = ->(principal) { principal.security_admin? }
```

In multi-tenant applications, the mounted controller must also expose a
non-null `current_account`; otherwise console access is rejected.

Release maintainers should run `bundle exec rake release:verify`. It executes
the reproducible suite, builds the gem, emits `.sha256` and `.spdx.json`
artifacts, and installs the generated gem into an isolated temporary directory.

---

# Upgrading 0.3.2 → 0.4.0

AgentKit 0.4 adds A2A 1.0 without removing the 0.3 JSON-RPC API. New peers
should discover `/.well-known/agent-card.json` and use the HTTP+JSON endpoints
under `/agentkit/a2a`.

Install and run migration `014_create_agentkit_a2a_tasks`. It provides durable,
tenant-scoped task polling across restarts and multiple Rails workers.

For multi-tenant applications, resolve the account from the Rails request and
optionally customize domain fields in the generated card:

```ruby
config.a2a.tenant_resolver = ->(request) { Vendor.find_by(subdomain: request.subdomains.first) }
config.a2a.card_builder = lambda do |card, context|
  card.merge(iconUrl: context.account.logo_url)
end
```

Use `security_schemes` and `security_requirements` to advertise the host's real
authentication mechanism. The default declares HTTP Bearer authentication;
`X-A2A-Key` remains accepted for legacy callers.

Card signatures are optional. To publish an RS256 signature:

```ruby
config.a2a.signing_key = ENV.fetch("AGENTKIT_A2A_SIGNING_KEY_PEM")
config.a2a.signing_key_id = "provider-2026-01"
config.a2a.signing_jwks_url = "https://agents.example/.well-known/jwks.json"
```

Outbound verification accepts `:disabled`, `:if_present` (the default), or
`:required`. Populate `trusted_keys` with `kid => public_key` entries. AgentKit
does not automatically trust arbitrary `jku` URLs.

Once every peer uses A2A 1.0, disable the old discovery route with
`config.a2a.legacy = false`.

---

# Upgrading 0.3.1 → 0.3.2

Install and run migrations `011`, `012` and `013`. Historical unscoped rows are
assigned to `__global__`; the rollback is intentionally irreversible because
merging tenant security boundaries is unsafe.

With `multi_tenant = true`, all AgentKit reads, mutations, reports and jobs now
require an `Agentkit::Context` or serialized `Agentkit::Scope`. Queue producers
must include the scope passed by the kernel; legacy unscoped jobs fail closed
and should be discarded or re-enqueued with their original tenant.

Skill import now returns a quarantined Team Memory asset. Approve the generated
`skill_activation` suggestion before expecting the skill in `SkillRegistry`.

`force_sync` only expresses transport waiting preference and never bypasses
approval. A2A mutation callers should always provide an `idempotency_key`.

---

# Upgrading 0.2.1 → 0.3.1

## Required steps

1. Point the application at `agentkit-rails`, version `~> 0.3.1`.
2. Install the engine migrations and run them:

   ```bash
   bin/rails agentkit:install:migrations
   bin/rails db:migrate
   ```

3. Confirm that migration `010_add_agentkit_tenancy.rb` ran. It adds
   `tenant_key` and `account_id` to RAG and Team Memory tables and replaces
   global uniqueness constraints with tenant-scoped ones.
4. Applications with more than one tenant must enable strict scoping:

   ```ruby
   Agentkit.configure do |config|
     config.multi_tenant = true
   end
   ```

5. Run every RAG and Team Memory operation inside an `Agentkit::Context`, or
   pass `tenant_key:` explicitly. Unscoped access raises `ConfigurationError`
   when strict scoping is enabled.

   ```ruby
   context = Agentkit::Context.new(account: current_account)

   Agentkit.with_context(context) do
     Agentkit::RAG.retrieve("refund policy", corpus_name: "handbook")
     Agentkit::TeamMemory.load_assets(team: "Operations")
   end
   ```

## Database security

The engine now enforces tenant scope in its Ruby and ActiveRecord adapters.
Applications that use PostgreSQL Row-Level Security should add their own RLS
policies for the six new tables, using the same session tenant mechanism as the
host application:

- `agentkit_knowledge_chunks`
- `agentkit_teams`
- `agentkit_memory_assets`
- `agentkit_wiki_pages`
- `agentkit_code_symbols`
- `agentkit_asset_bindings`

AgentKit deliberately does not install a generic RLS policy because host
applications differ in how they place the current tenant in a PostgreSQL
session variable. RLS remains a second line of defence in addition to the
engine's mandatory scopes.

## Embedding dimensions

The default RAG schema uses `vector(1536)`. If the configured embedding model
returns another size, create a host migration for the desired vector dimension
and set:

```ruby
config.rag.embedding_dimensions = 3072
```

AgentKit now raises a clear configuration error before writing a vector whose
size does not match this setting.

## Compatibility notes

- Existing Agent, Flow, HITL, Memory, Audit and Factory APIs remain compatible
  with 0.2.1.
- Team names are unique per tenant instead of globally.
- RAG chunk identifiers are unique per tenant and corpus.
- `RAG.drop_corpus` only removes the current tenant's corpus.

---

# Upgrading 0.1 → 0.2

## TL;DR for the six existing applications

1. Delete `vendor/gems/agentkit-rails-0.1.0` and the patches on top of it. Every
   fix those forks carried is upstream now.
2. Point the Gemfile at `gem "agentkit-rails", "~> 0.2"`.
3. Run the new migrations. The old tables are read-compatible; new columns are
   additive.
4. Replace the initializer's flat keys with the nested ones (table below).
5. Nothing in `app/agents/` has to change: the v0.1 agent surface is preserved.

## Engine boot for existing applications

If `rails agentkit:install:migrations` is missing or the classes under the
engine's `app/models` do not autoload, AgentKit is being required for the first
time from `config/initializers/agentkit.rb`. That happens after Rails has
already collected its engines.

Run the installer again, or add these lines to `config/application.rb` after
the Rails framework requires and before the application class:

```ruby
require "agentkit"
require "agentkit/engine"
```

The operation is idempotent. Once those lines are present, remove any
`require "agentkit"` left in the initializer.

## Configuration mapping

| 0.1 | 0.2 |
|---|---|
| `config.llm_default_model = "x"` | `config.llm.profiles[:default] = Agentkit::ModelProfile.new(model: "x")` |
| `config.llm_fast_model` / `_complex` / `_code` / `_vision` | `config.llm.profiles[:fast]` / `[:complex]` / `[:code]` / `[:vision]` |
| `config.embedding_model` | `config.memory.embedding.model` |
| `config.embedding_batch_size` (never read in 0.1) | `config.memory.embedding.batch_size` |
| `config.hitl_level` | `config.hitl.level` |
| `config.dreaming_cron` / `_threshold` | `config.memory.dreaming.cron` / `.threshold` |
| `config.auto_consolidate` | `config.memory.dreaming.supersede_sources` |
| `config.features = [:rag]` | `config.memory.level = :hybrid` (see below) |
| `config.anthropic_api_key` etc. | `config.llm.anthropic_api_key` etc. |

Unknown keys no longer raise: `config.my_custom_thing = 1` is kept, so the
`Agentkit::Configuration.class_eval` monkeypatch that `dos/maas` needed can go.

## Memory: pick a level instead of a boolean

`totallook` turned memory off entirely with an env var and lost its audit trail.
That trade-off no longer exists:

```ruby
config.memory.level            = :keyword       # search with zero API calls
config.memory.embedding.policy = :never
```

Recommended starting point for an app that was on `features: [:rag]`:

```ruby
config.memory.level            = :hybrid
config.memory.embedding.policy = :on_promotion
config.memory.embedding.dedupe = true
```

Check what it will cost before enabling anything:

```bash
POLICY=on_promotion rails agentkit:estimate_embeddings
```

## Deprecated, still working

- `Agentkit::ApplicationAgent` → alias of `Agentkit::Agent`.
- `Agentkit::AgentTriggerable` → alias of `Agentkit::Triggerable`.
- `Agentkit::ModelRouter.resolve(:complex)` still returns a model string.
- `agent_log(event:, payload:)` still exists; it emits telemetry now.

## Removed, with a replacement

| Removed | Replacement |
|---|---|
| `Agentkit::MemoryEngine.store/search/cluster_raw` | `Agentkit::Memory.store/recall`, `Cognition.run(:dreaming)` |
| `Agentkit::HITLEngine.suggest!` | `Agentkit::HITL.suggest!` (same keywords) |
| `Agentkit::DreamingJob` | `Agentkit::CognitionJob.perform_later("dreaming")` |
| `Agentkit::AgentWorkerJob` | `Agentkit::TriggerJob` |
| `CodeGeneration#apply!` | `Agentkit::Factory.patch!` (emits a PR, never writes) |
| `Agentkit::A2aController` | out of scope; keep your own controller |

## Things you can now delete from your app

- `astra`: `Astra::CreditGuard` (→ usage events + budget), `AgentPromptVersion`
  (→ `Agentkit::Prompt` with canary).
- `maas`: the `after_commit` monkeypatch on `Agentkit::AgentSuggestion`
  (→ `Agentkit::HITL.on`), the `perform_in` patch, the rewritten jobs.
- `tres`: the `hitl_engine.rb` edit, the `agent_log` override, `parse_json`.
- `totallook`: the `memorize!` override (→ `memory_policy`), the manual Qwen
  model registration (→ `adapter: :openai_compatible`).
- `cuatro`: the random-embedding stub (→ `level: :keyword` in dev, deterministic
  fake in test).
