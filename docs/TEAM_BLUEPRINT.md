# Declarative team blueprints

`Agentkit::Harness::Organization::TeamBlueprint` turns a small onboarding
interview into an immutable, digest-addressed design contract. It helps a host
compare a one-agent baseline with an optional team candidate without pretending
that a prompt is an executable organization.

The class is deliberately upstream of runtime orchestration. Constructing a
blueprint or converting it to a `Harness::Manifest` does not call a model,
instantiate an agent, register a tool, create a `Flow`, grant a permission,
schedule work, persist data or activate a topology.

## Five bounded intake answers

`TeamBlueprint.questions` exposes exactly five fields:

1. `business_domain`
2. `desired_outcome`
3. `operator_strengths`
4. `weekly_hours`
5. `first_delegation`

Answers are bounded identifiers and numbers, not prompt text or secrets. Keep
long-form interview notes in the host's authorized store and put only a safe
reference and digest in `metadata`.

## Required contracts

A blueprint requires:

- a `Harness::Goal` whose approval names cover every effectful or risky action;
- a selected use case grounded by an evidence digest, plus explicit reasons for
  deferred cases;
- a `WorkloadContract` with capability, check, agent, cost, latency and human
  time bounds;
- a `Topology` baseline with exactly one agent and complete capability coverage;
- an optional, distinct multi-agent candidate with exactly one coordinator;
- closed agent, tool, handoff and workflow contracts made only from identifiers,
  references, numeric bounds and SHA-256 digests;
- separate training and holdout sets, an isolated verifier or external gate,
  human review and rollback;
- bounded turns, calls, subcalls, delegation depth and workload resources;
- a seven-day review plan ending in a human-owned pilot decision; and
- a closed JSON-object output schema for a declarative `Harness::Manifest`.

The candidate is optional. With no candidate the status is `baseline_ready` and
delegation budget must be zero. With a valid candidate the status is
`ready_for_evaluation`; that means only that the design can enter evaluation,
not that it is recommended or authorized.

## Minimal shape

```ruby
O = Agentkit::Harness::Organization

blueprint = O::TeamBlueprint.new(
  id: "weekly-market-brief-team",
  intake: {
    business_domain: "market_research",
    desired_outcome: "weekly_brief",
    operator_strengths: ["editorial_judgment"],
    weekly_hours: 10,
    first_delegation: "source_research"
  },
  goal: goal,
  selected_use_case: {
    id: "weekly_brief",
    objective: "evidence_bound_brief",
    rationale: "largest_bounded_time_saving",
    first_metric: "accepted_briefs",
    expected_hours_saved: 4,
    evidence_digest: selection_evidence_digest,
    capabilities: %w[research synthesis verification]
  },
  deferred_use_cases: [
    { id: "outreach", reason: "higher_external_risk" }
  ],
  workload: workload,
  baseline: one_agent_topology,
  candidate: research_review_topology,
  agents: agent_contracts,
  tools: tool_contract_references,
  handoffs: handoff_contracts,
  workflow: workflow_steps,
  quality: quality_contract,
  budget: execution_bounds,
  launch_plan: seven_day_plan,
  output_contract: closed_json_schema,
  metadata: {
    source_reference: "onboarding/session-42",
    source_digest: onboarding_digest,
    labels: ["pilot"]
  }
)
```

Agent contracts reference prompt and input/output schema digests; they do not
embed prompt bodies. Tool declarations reference a `ToolContract` digest; they
do not carry an adapter or callable. Every `internal` or `external` tool and
every `sensitive`, `irreversible` or `privileged` tool needs an approval gate
already required by the goal.

Handoff contracts must match candidate topology edges exactly. Workflow steps
form a DAG, cover all active members and workload checks, and converge on one
coordinator-owned terminal decision. Effectful steps also require a goal gate.

## Safety flags and serialization

Every valid blueprint returns:

```ruby
blueprint.authorizes?       # false
blueprint.auto_activates?   # false
blueprint.requires_review?  # true
blueprint.digest            # sha256:...
```

`TeamBlueprint.from_h(blueprint.to_h)` performs a strict, fail-closed round
trip. Unknown keys and altered safety flags are rejected.
`to_manifest(topology: :baseline)` and `to_manifest(topology: :candidate)` emit
separate compositions containing only their own `subagent`, `tool_guidance`
and `guardrail` components, with empty permissions and `authorizes: false`.
`to_manifests` returns both when a candidate exists. The host still decides
whether to store or evaluate either manifest.

## From design to production

1. Build the baseline-only blueprint and evaluate it first.
2. Add a candidate only when each additional agent has a declared separation
   reason such as a permission boundary, independent verification or a truly
   specialized capability.
3. Collect matched `Organization.instrument` evidence for baseline and
   candidate.
4. Build `AgentProfile` and `CoordinationReport` results on disjoint training
   and holdout samples.
5. Submit only approved topologies to `CompositionStudy`.
6. Use `CompositionPilot` for a controlled pilot and
   `CompositionGovernance` for independently reviewed adoption or rollback.

The blueprint does not bypass any of these stages. A host must separately
resolve references, authorize runtime identities, enforce budgets, register
tools and agents, and preserve tenant-scoped audit evidence.
