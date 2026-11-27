# Telemetry delivery and tenant diagnosis

This is the first consolidation step: make observation failures visible and
prevent duplicate database measurements on retry. It does not change decision
permissions, experiment promotion or business rules.

## Delivery contract

- Emission queues an event with a UUID `event_id`. Buffer append/drain is atomic.
- Only one flush writes sinks at a time. Emission continues during slow writes;
  a concurrent or recursive flush returns without starting a second delivery.
- A successful sink is not replayed because another sink failed. Pending work
  stays attached to its original sink if configured backends change.
- PostgreSQL (migration 032) and the memory backend deduplicate event IDs.
  The memory backend only remembers identities within its retained ring.
- Custom sinks can opt into retry with `idempotent? == true`. Returning `false`
  from `write` means unavailable; raising means failed or ambiguous. Other
  returns acknowledge delivery. The sink must not mutate supplied events.
- Non-idempotent sinks, including log/OTel/StatsD shims, are not retried after
  failure: partial delivery cannot safely be distinguished from no delivery.
- The incoming queue and each sink's pending queue hold at most 10,000 events.
  Overflow discards new deliveries and increments a loss counter. Successful
  sinks continue receiving events even when another sink's queue fills.

`Telemetry.delivery_health` reports `buffered_events`, `pending_deliveries`,
`failed_writes` and `dropped_deliveries`. A delivery is one event to one sink;
loss counters may exceed the number of distinct events. Failed non-idempotent
writes count as ambiguous losses even if the sink received some events.

`complete` is conservative: false while buffered/in-flight/pending work exists,
or after any failure/loss since process initialization or explicit `reset!`.
These are process-wide diagnostics, not per-tenant evidence coverage. A true
value does not prove historical completeness, absence of sampling, completeness
of external sources, or delivery from other workers. `reset!` discards queues
and counters and is for tests or quiescent reconfiguration, not recovery.

## Rails responsibilities

Apply migration 032 before running the database sink. Run `Telemetry.flush!`
periodically in each producer process and during graceful shutdown. The existing
engine shutdown hook remains; this change installs no timer or background job.
Retries occur on later flushes, with no tight retry loop. Hosts should choose a
bounded polling interval and monitor delivery health.

The buffer is **not durable across process termination**. Database writes inside
a caller-owned transaction remain subject to that transaction's rollback. Use
the transactional Journal/outbox for authoritative evidence and external effects.
Database identity deduplication does not turn telemetry into exactly-once delivery.
Backend exception messages are excluded from delivery warnings to avoid exposing
payloads; event content still needs application-owned redaction before emission.

`rails agentkit:doctor TENANT=... ACCOUNT_ID=...` filters activity by tenant and
optional account. Its delivery warning is explicitly process-wide and cannot
inspect another worker's in-memory queue. A missing tenant in multi-tenant mode
continues to run schema-only checks.

## Next consolidation steps

After this foundation, the proposed sequence is:

1. A Rails reference application connecting evidence, decisions, outbox execution,
   observed outcomes and a controlled experiment, including crash recovery.
2. A shared hierarchical reservation/accounting port across execution subsystems.
3. A read-only operational projection joining goals, evidence, budgets and blockers.
4. Versioned end-to-end evaluations and common evidence/memory lifecycle policies.

These later steps are not implemented by this telemetry change. Durable telemetry
spooling and per-scope coverage manifests also remain separate work; studies
must not interpret process-local delivery health as a complete dataset certificate.
