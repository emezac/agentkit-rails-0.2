# SDD — AgentKit 0.9.0 Distributed Exploration

Status: implemented  
Scope: distributed world execution, tenant quotas, read-only operations UI

## Problem

0.8 can resume a world safely, but callers still own process placement and
capacity admission. A production deployment needs horizontal workers without
serializing Ruby closures, duplicate delivery without duplicate spend, bounded
tenant consumption, and enough operational visibility to detect queued,
running or ambiguous work.

## Decisions

### Distribution boundary

The delivery unit is one exploration world. `Exploration.enqueue` persists a
complete `queued` checkpoint before calling the dispatcher. Active Job carries
only `world_id` and an explicit scope. The worker resolves the recorded policy,
generator and evaluator identities from boot-time registries, acquires the
world lease, and executes the existing checkpointed runner.

This boundary reuses 0.7.1 attempt idempotency and reconciliation while keeping
the coordination protocol small. Multiple worlds scale horizontally; probes
inside a round remain bounded local threads. Cross-process probe fan-out is not
claimed by this release.

### Provenance

Generators use an immutable manifest containing name, version, source digest
and sanitized metadata. A registration with the same name/version and a
different digest fails. Queued worlds require generator and evaluator
manifests. Historical worlds without generator provenance remain replayable
but cannot be distributed retroactively.

### Delivery semantics

- Persist-before-dispatch prevents invisible queue work.
- A terminal world is a duplicate-delivery no-op.
- A live lease rejects a concurrent worker.
- Expired lease takeover uses the existing attempt ambiguity rules.
- Missing registry entries or digest mismatch fail closed.
- Operators may redeliver only queued/running worlds with `redispatch`.

The guarantee is at-least-once delivery with idempotent durable effects, not
exactly-once execution of arbitrary external generator side effects.

### Quotas

Two UTC calendar-day resources are accounted per tenant/account:

- `worlds`: reserved before a local run or distributed enqueue is admitted.
- `attempts`: reserved once per world/round before attempt records are created.

Each reservation has a durable unique key. The usage row is locked while the
limit is checked, incremented and linked to its reservation in one database
transaction. Redelivery returns the existing usage without incrementing it.
A nil limit records usage without rejecting; zero rejects all new capacity.

World-quota exhaustion raises `ExplorationQuotaExceeded` before persistence.
Attempt-quota exhaustion closes the already valid evidence as `completed` with
`stop_reason=quota_exhausted` and releases the lease.

### Dashboard

`GET /agentkit/exploration` is read-only and uses `ApplicationController`, so
the existing console guard, principal resolver, tenant scope, CSRF policy,
security headers and no-store caching apply. The view contains aggregate
states, quota usage and a bounded recent-world list. It omits objectives,
candidate material, tree diagnostics, evaluator metadata and lease owners.

## Data model

Migration 021 adds:

- `generator_digest` and `generator_manifest` to exploration worlds;
- a `(tenant_key, status, created_at)` operations index;
- daily quota usage rows unique by tenant/account/resource/day;
- quota reservations unique by tenant/resource/reservation key.

Global/non-account execution uses account id `0` in quota ledgers so PostgreSQL
NULL uniqueness cannot create parallel counters.

## Configuration

```ruby
config.exploration.execution = :local # or :distributed
config.exploration.queue = :agentkit_exploration
config.exploration.daily_world_limit = nil
config.exploration.daily_attempt_limit = nil
config.exploration.quota_resolver = nil
```

Distributed execution requires the Active Record store. Server ceilings from
0.7 and statistical gates from 0.8 remain unchanged.

## Non-goals

- Cross-process fan-out of individual probes.
- Exactly-once semantics for arbitrary external side effects.
- Automatic policy promotion or holdout access from the dashboard.
- Queue backend installation or queue autoscaling.
- Monetary/token quotas; hosts can add those from provider telemetry later.

## Acceptance criteria

- Registry-backed worlds execute through Active Job from durable queued state.
- Duplicate delivery does not create attempts or consume quota twice.
- World and attempt limits are atomic and tenant-scoped.
- Quota exhaustion produces an explicit, replayable terminal state.
- Dashboard access is fail-closed and output contains no raw objectives.
- Migration, doctor, unit, integration, eager-load and release checks pass.
