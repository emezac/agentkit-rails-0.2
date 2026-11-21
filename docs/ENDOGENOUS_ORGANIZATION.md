# Organizational telemetry and coordination profiles

This opt-in surface implements the measurement foundation for endogenous team
formation. It does not form teams at runtime. It measures host-approved
organizations so a later governed study can compare compositions from evidence
instead of assuming that adding agents helps.

## Boundaries

- No model call, agent creation, delegation or promotion is performed by this
  API.
- Agent identities, roles, capabilities, topology and permissions are provided
  by trusted host code.
- A verifier must retain an independent-context or permission boundary.
- Raw request IDs, prompts, results and context bodies are not stored.
- Team blueprints store only bounded identifiers, safe references and digests
  for onboarding, prompts and tool contracts; never callables or credentials.
- Reports contain bounded identifiers, numeric measurements and evidence
  digests. They do not grant execution authority.
- Coordination is reported as observable deltas and Pareto relationships. The
  API does not claim to estimate an economic phase-transition parameter.

## P-1: declarative team blueprint

`Organization::TeamBlueprint` captures exactly five bounded intake answers,
an explicitly selected use case, a mandatory one-agent baseline and an optional
team candidate. It validates agent responsibilities, tool gates, exact handoff
contracts, an acyclic workflow, independent quality review, resource budgets
and a seven-day launch plan before any runtime object exists.

The candidate is a design to evaluate, not a recommendation. The blueprint and
its optional declarative manifest always expose `authorizes: false`,
`auto_activates: false` and `requires_review: true`; neither surface registers
or invokes agents and tools. See [Declarative team
blueprints](TEAM_BLUEPRINT.md) for the complete contract and example.

## P0: organizational telemetry

Define an immutable topology:

```ruby
O = Agentkit::Harness::Organization

topology = O::Topology.new(
  id: "research-review", pattern: "verifier",
  members: [
    {
      agent: "researcher", role: "research",
      capabilities: ["research", "synthesis"],
      model_profile: "default"
    },
    {
      agent: "reviewer", role: "verifier",
      capabilities: ["verification"],
      independent_context: true
    }
  ],
  edges: [{ from: "researcher", to: "reviewer", kind: "verification" }]
)
```

Wrap an actual call:

```ruby
O.instrument(
  request_id: job.id,
  organization_id: "research",
  topology: topology,
  agent: "researcher",
  role: "research",
  capability: "research",
  model_profile: "default",
  toolset_digest: Agentkit::Harness.digest(allowed_tools),
  skills_digest: Agentkit::Harness.digest(skill_versions),
  policy_digest: Agentkit::Harness.digest(policy),
  context: authenticated_context
) do |measures|
  result = Researcher.call(job)
  measures[:success] = result.accepted?
  measures[:quality] = result.quality
  measures[:context_bytes] = result.context_bytes
  measures[:retries] = result.retries
  result
end
```

Every nested telemetry event receives the allowlisted organization dimensions.
The final `organization.call` event aggregates nested `llm.call` tokens, cost
and retries by a fresh child run ID. Host measurements are optional; missing
success or context size remains explicitly incomplete rather than becoming
zero.

Export measured calls to existing delegation diagnostics:

```ruby
traces = O::TraceSet.from_telemetry(since: 7.days.ago, context: authenticated_context)
report = traces.analyze(minimum_requests: 5, context: authenticated_context)
```

The export enforces tenant/account scope and uses only request digests. It adds
observed capabilities, success coverage, handoff counts, failed handoffs,
context retention, retries, duplicate work and verifier rejections to the
existing report.

## P1: capability and coordination profiles

An `AgentProfile` is derived from evaluated observations. Each observation
requires a task digest and evidence digest:

```ruby
profile = O::AgentProfile.build(
  agent: "researcher",
  identity: {
    model_profile: "default",
    skills_digest: Agentkit::Harness.digest(skill_versions)
  },
  observations: [{
    capability: "research",
    task_digest: Agentkit::Harness.digest(task_contract),
    evidence_digest: Agentkit::Harness.digest(grade_receipt),
    success: true, quality: 0.91, cost_usd: 0.03, latency_ms: 420
  }],
  coordination_observations: [{
    evidence_digest: Agentkit::Harness.digest(handoff_receipt),
    handoff_success: true, context_retention: 0.88,
    conflict: false, retries: 0
  }]
)
```

Profiles report sample counts, success rates and mean quality/cost/latency per
capability. Changing a model, tool set, skill set or policy changes the identity
and requires new evidence.

For team-level comparison, define fixed bounds and a mandatory one-agent
baseline:

```ruby
workload = O::WorkloadContract.new(
  id: "market-brief",
  capabilities: ["research", "writing"],
  required_checks: ["policy", "citations"],
  max_agents: 3, max_cost_usd: 0.10, max_latency_ms: 2_000,
  minimum_samples: 3
)

coordination = O::CoordinationReport.build(
  workload: workload,
  topologies: [single_agent, specialist_pipeline],
  baseline: single_agent,
  observations: measured_runs
)
```

Each run binds a topology, request and evidence digest and reports success,
quality, cost, latency and every required check. Optional measurements include
human minutes, handoffs, handoff failures, context retention, duplicate work
and verifier rejections. Every topology must be evaluated over the same
multiset of request digests as the baseline; otherwise the comparison is
blocked instead of attributing a workload difference to coordination. The
declared member capabilities must also cover the workload contract.

The report compares every candidate with the baseline:

- `pareto_better`: no worse on success, quality, cost and latency, and strictly
  better on at least one;
- `pareto_worse`: the baseline dominates;
- `tradeoff`: neither dominates;
- `blocked`: insufficient or unmatched samples, missing capability coverage, a
  budget violation or a required-check failure in the baseline or candidate.

These measurements do not activate a composition by themselves. P2 through P4
add an opt-in governed study, controlled pilot and reviewed binding while
Factory N4, Exploration and A2A retain their existing authority boundaries.

## P2: governed composition study

`CompositionStudy` turns the P1 measurements into a bounded decision dossier.
It does not generate topologies or run probes. The host first creates separate
`CoordinationReport` objects from training and holdout requests, supplies
evidence-bound profiles, explicitly approves the exact topology digest set and
authorizes the evaluation from authenticated application context.

```ruby
study = O::CompositionStudy.new(
  id: "market-brief-composition",
  training_report: training_coordination,
  holdout_report: holdout_coordination,
  profiles: [researcher_profile, writer_profile, baseline_profile],
  approved_topology_digests: [
    single_agent.digest,
    specialist_pipeline.digest
  ],
  approved_by: "operator-42",
  approval_evidence_digest: Agentkit::Harness.digest(change_ticket),
  authorize: ->(action, request, context) {
    OrganizationPolicy.allowed?(action, request, context)
  },
  context: authenticated_context
)

recommendation = study.recommend
```

The study fails closed when:

- training and holdout reuse a request or evidence digest;
- workload, baseline or topology identities differ between phases;
- the approved digest set is incomplete or stale;
- an agent profile is missing, has insufficient evaluated samples, or no
  longer matches a declared model/tool/skill/policy identity;
- a candidate is not Pareto-better than the baseline in both phases.

Eligible candidates are compared with one another on success, quality, cost
and latency. The result is:

- `retain` when no candidate survives training and holdout;
- `recommend_review` when one candidate is the unique non-dominated result;
- `needs_choice` when several candidates remain non-dominated and a human must
  choose the tradeoff explicitly.

Every recommendation is immutable, redacted, size-bounded and reports
`authorizes: false` and `auto_promoted: false`. P2 therefore provides endogenous
selection inside an approved experimental boundary, not autonomous team
formation. Routing changes, agent creation and deployment remain host actions.

## P3: controlled composition pilot

`CompositionPilot` accepts only a P2 `recommend_review` result with one selected
candidate. It recomputes the study recommendation to reject stale or foreign
evidence, then binds the baseline and candidate topology digests to the mature
`Knowledge::BusinessExperiment` rail.

```ruby
pilot = O::CompositionPilot.new(
  study: study,
  recommendation: recommendation,
  version: "1",
  unit: "account",
  metrics: {
    "quality" => {
      "min" => 0, "max" => 100,
      "direction" => "maximize", "max_harm" => 0
    },
    "cost_cents" => {
      "min" => 0, "max" => 10_000,
      "direction" => "minimize", "max_harm" => 0
    }
  },
  primary_metric: "quality",
  starts_at: 1.hour.from_now,
  enrollment_ends_at: 2.days.from_now,
  analysis_at: 3.days.from_now,
  window_seconds: 86_400,
  max_units: 100,
  min_per_arm: 20,
  gates: {
    "control" => baseline_gate.digest,
    "treatment" => candidate_gate.digest
  },
  measurement_versions: {
    "quality_ledger" => "v1",
    "cost_ledger" => "v1"
  },
  journal: decision_journal,
  authorize: ->(action, context) { PilotPolicy.allowed?(action, context) },
  eligible: ->(unit_id, context) { CanaryCohort.include?(unit_id, context) },
  bind_unit: ->(unit_id, arguments, _context) {
    arguments.fetch(:account_id).to_s == unit_id.to_s
  }
)

pilot.register(context: operator_context)
pilot.approve(reason: "bounded organizational canary", context: independent_reviewer_context)

assignment = pilot.assign(unit_id: account.id.to_s, context: operator_context)
pilot.execute(
  unit_id: account.id.to_s,
  gate: assignment["arm"] == "control" ? baseline_gate : candidate_gate,
  arguments: { account_id: account.id },
  context: operator_context
) do |_arm, assigned_topology|
  HostRouter.call(topology: assigned_topology, account: account)
end
```

The underlying experiment provides durable, tenant-scoped controls already
used elsewhere in AgentKit:

- registration and approval must be performed by different principals;
- the eligible host cohort limits the overall canary population;
- units inside that cohort are assigned 50/50 with a committed HMAC seed;
- the quota is serialized across workers and assignments are stable;
- execution requires the arm's exact `DecisionGate` and is idempotent;
- `stop` permanently blocks later assignment and execution;
- missing outcomes remain missing and cannot silently become zero;
- fixed-horizon analysis and final review never promote a topology.

P3 requires the Rails persistence installed by migration 025 and a shared
transactional decision journal. It intentionally requires at least 40 units
and 20 per arm because it is an evidence-producing controlled pilot, not a
single-request smoke test. Stopping prevents future exposure; compensating
already committed domain effects remains the responsibility of the host gate.

## P4: reviewed adoption and rollback

P4 converts only an approved, unrevoked P3 analysis into a pending
organizational review. It reuses the durable exploration review and binding
store from migration 022, under an isolated `organization:` target namespace.
No new table or migration is required.

```ruby
review = O::CompositionGovernance.submit!(
  target: "support-routing",
  pilot: pilot,
  context: operator_context
)

approved = O::CompositionGovernance.approve!(
  review,
  actor: "organization-owner",
  reason: "P3 outcome and operational assumptions reviewed",
  authorize: ->(action, request, context) {
    OrganizationPolicy.allowed?(action, request, context)
  },
  context: owner_context
)
```

The P4 approver must differ from the human who approved the P3 result. Approval
is atomic with the active binding: if another adoption changed the incumbent
after submission, the stale review fails and a new study is required.

The binding contains only topology identity and evidence references. Host code
must authorize every resolution and return the exact immutable topology from a
trusted registry:

```ruby
topology = O::CompositionGovernance.resolve(
  target: "support-routing",
  resolver: ->(digest, _context) { TopologyRegistry.fetch(digest) },
  authorize: ->(action, request, context) {
    OrganizationPolicy.allowed?(action, request, context)
  },
  context: request_context
)

HostRouter.call(topology: topology, request: request)
```

The resolver fails closed when the registry returns a topology with a different
digest. Since the topology digest covers members, roles, capabilities, model
profile and tool/skill/policy digests, component drift cannot silently inherit
the active binding.

Rollback is an explicit reviewed transition and restores the prior binding (or
removes the first binding):

```ruby
O::CompositionGovernance.rollback!(
  approved,
  actor: "organization-owner",
  reason: "production guardrail regression",
  authorize: ->(action, request, context) {
    OrganizationPolicy.allowed?(action, request, context)
  },
  context: owner_context
)
```

P4 records required audit evidence for submission, approval, rejection and
rollback. It does not register implementations, instantiate agents, execute a
topology or automatically adopt the next candidate.

## Completion boundary

P-1 through P4 complete the safe kernel lifecycle:

0. declare a bounded, review-only blueprint and one-agent baseline;
1. observe organizational work without extra model calls;
2. build evidence-bound capability and coordination profiles;
3. compare approved compositions on disjoint training and holdout evidence;
4. run a durable, independently approved controlled pilot;
5. adopt or roll back an exact topology binding under human governance.

There is intentionally no automatic P5 that invents organizations, expands
permissions, registers implementations or continuously moves production
traffic. Those actions would add model cost and turn measured endogenous
selection into autonomous organizational control. Applications may generate
candidate topologies outside the kernel, but candidates must re-enter at P1/P2
and traverse the same evidence, pilot and review gates.
