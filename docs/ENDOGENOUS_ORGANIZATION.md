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
- Reports contain bounded identifiers, numeric measurements and evidence
  digests. They do not grant execution authority.
- Coordination is reported as observable deltas and Pareto relationships. The
  API does not claim to estimate an economic phase-transition parameter.

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

These are measurements for a future governed composition study. Factory N4
remains human-reviewed, and Exploration, A2A and runtime team selection remain
unchanged.

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
