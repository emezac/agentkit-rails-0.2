# SDD — AgentKit 1.0 Promotion Governance

Status: implemented  
Scope: durable evidence dossiers, human decisions, reversible bindings,
operational readiness and quota-ledger maintenance

## Problem

0.9 can discover, replay, compare and operate policies at production scale,
but its statistically supported recommendation is transient. A process restart
loses the decision context, operators cannot prove which evidence was reviewed,
and each host must invent activation and rollback semantics. Direct automatic
promotion would violate the separation between evidence and executable code.

## Decisions

### Evidence boundary

`submit_recommendation!` accepts only a `recommend_review` result whose
incumbent/candidate match a significant two-policy holdout comparison. The
dossier stores evaluation aggregates, split and history digests, Pareto
descriptors and the statistical comparison. It omits individual replay paths
and cannot be edited after insertion.

Submission is idempotent by tenant, account, target and evidence digest. The
same evidence cannot create an unbounded review queue.

### Human state machine

The lifecycle is:

```text
pending ──approve──> approved ──rollback──> rolled_back
   └──────reject──────────────────────────> rejected
```

Every transition has a human actor. Reject and rollback require a reason.
Row locks plus `lock_version` serialize competing decisions. A terminal review
cannot be decided again.

### Declarative activation

Approval upserts one binding per tenant/account/target with the candidate's
name, version, digest, source review and monotonic generation. It does not
mutate `Policies::Registry`, load source, eval content, dispatch a worker or
change application routing by itself. Hosts may consume the binding only by
matching it to already-deployed, versioned code.

The review records the previous binding. Rolling back the active review either
restores that descriptor with a new generation or removes the binding when
none existed. A superseded review cannot roll back over a newer binding.

### Audit transaction

Submission and decisions call Audit with `failure_mode: :required`. Active
Record stores execute the audit append inside the review/binding transaction;
if evidence persistence fails, the state transition rolls back. Audit payloads
contain only identifiers, digests, actor/reason and binding generation.

### Operator surface

The existing exploration dashboard lists dossiers and active status. POST
controls for approve, reject and rollback inherit the console's fail-closed
guard, resolved principal, explicit tenant context, CSRF protection, CSP and
no-store headers. The UI never renders raw worlds, candidate artifacts or
executable implementations.

### Readiness and retention

`Exploration.readiness` reports configuration, audit, schema and dispatcher
checks plus queued/running/ambiguous work and pending reviews. It is a pure
probe. `Exploration.maintain!` defaults to dry-run and, when explicitly
applied, deletes only quota usage/reservation rows older than
`quota_retention_days`. It cannot delete evidence or audit history.

## Data model

Migration 022 adds:

- `agentkit_exploration_reviews`, with immutable provenance/evidence fields,
  decision metadata and optimistic locking;
- `agentkit_exploration_policy_bindings`, unique by tenant/account/target,
  with current descriptor, source dossier and monotonic generation.

Global/non-account scope uses account id `0`, avoiding PostgreSQL NULL
uniqueness gaps.

## Stable public surface

```ruby
Agentkit::Exploration::API_VERSION # => "1.0"
Agentkit::Exploration.submit_recommendation!(target:, recommendation:, scope:)
Agentkit::Exploration.approve_recommendation!(review, actor:, reason:, scope:)
Agentkit::Exploration.reject_recommendation!(review, actor:, reason:, scope:)
Agentkit::Exploration.rollback_recommendation!(review, actor:, reason:, scope:)
Agentkit::Exploration.reviews(scope:, status:, limit:)
Agentkit::Exploration.policy_binding(target:, scope:)
Agentkit::Exploration.policy_bindings(scope:)
Agentkit::Exploration.readiness(scope:)
Agentkit::Exploration.maintain!(scope:, dry_run:, at:)
```

## Non-goals

- Generated-code execution, deployment or dynamic eval.
- Automatic approval from a p-value, confidence interval or Pareto rank.
- Rollback of external side effects performed by application-owned adapters.
- Pruning worlds, attempts, dossiers, bindings or audit entries.

## Acceptance criteria

- Unsafe or inconclusive recommendations fail before dossier persistence.
- Submission is idempotent and tenant/account isolated.
- Approval, rejection and rollback are serialized, audited and durable.
- Approval cannot modify the policy registry or execute a candidate.
- Rollback restores the previous binding and cannot overwrite a newer one.
- Dashboard actions remain behind existing console security controls.
- Readiness, maintenance, doctor, migration, eager-load, full suite and package
  verification pass.
