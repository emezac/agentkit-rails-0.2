# AgentKit adoption paths

AgentKit is a Ruby/Rails kernel with optional capabilities. Start with the
smallest path matching the application; migrations are additive and the host
remains responsible for business semantics, authenticated identities and
external effects.

| Path | Kernel surfaces | Rails host owns | Read first |
| --- | --- | --- | --- |
| Agent with tools | AgentLoop, ToolContract, ExecutionBudget | Tool permissions, provider keys, current domain data | [README](../README.md) |
| Verified decisions | Ontology, ActiveRecordSource, DecisionGate, Journal | Approved rules, source locking, authorization, action/outbox | [Rails evidence](RAILS_EVIDENCE_AND_DECISION_GATES.md) |
| Learning from business outcomes | BusinessLearning, BusinessExperiment, BusinessValueEvaluation | Final metrics, cohorts, customer harm, human review | [Business loop](BUSINESS_LEARNING_LOOP.md), [value evaluation](BUSINESS_VALUE_EVALUATION.md) |
| Reviewed memory | Consolidation, EvidenceLifecycle | Source archive, versioning, retention, deletion and lifecycle events | [Consolidation](EVIDENCE_GROUNDED_MEMORY_CONSOLIDATION.md), [lifecycle](EVIDENCE_LIFECYCLE.md) |
| Production operation | UnattendedRun, SharedBudget, Escalations, OperationalProjection | Isolated workers, provider caps, scheduler, reconciliation, dashboard policy | [Unattended runs](SUPERVISED_UNATTENDED_RUNS.md), [budget](SHARED_BUDGETS.md), [view](OPERATIONAL_PROJECTION.md) |

For a runnable business process, use the [Rails returns reference app](../examples/returns_app/README.md).
It shows approval, verified evidence, an outbox, simulated external effect,
recovery and a controlled routing pilot. Add only the modules needed by the
application; none of these paths grants the model direct database or deployment
authority.

## API maturity and release boundary

The top-level AgentLoop, Flow, HITL, Knowledge and Memory APIs are versioned
with the gem and covered by the full test suite. New opt-in surfaces listed in
the current `Unreleased` changelog have not yet received a numbered release.
Treat their contracts as reviewable but still subject to change until the next
release is cut. Read [UPGRADING](../UPGRADING.md) before enabling migrations or
changing host adapters. The shipped gem version remains 1.14.0; commits on
`main` are not a published gem release.

For every adoption, verify three boundaries in the host: a scoped read cannot
cross tenant/account, a retry cannot repeat an external effect, and missing
evidence or provider usage never becomes a successful result. The repository's
integration suite exercises these seams against PostgreSQL; the host must add
domain-specific fixtures and deployment checks.
