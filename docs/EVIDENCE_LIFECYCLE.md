# Evidence and memory lifecycle

`Memory::EvidenceLifecycle` connects committed Rails source changes to the
existing reviewed-memory invalidation mechanism. It reuses the scoped
`Knowledge::Journal` event and delivery rails (migration 024) and memory heads
(migration 030). It adds no table, job, model call or automatic permission.

```ruby
lifecycle = Agentkit::Memory::EvidenceLifecycle.new(
  journal: journal, consolidation: reviewed_library,
  authorize: ->(action, event, context) {
    SourceLifecyclePolicy.allowed?(action, event, context)
  }
)

# From a trusted after-commit source-change handler:
lifecycle.record(id: "policy-change-812", reference: "policy/returns",
  source_digest: Agentkit::Knowledge.digest(new_policy_bytes),
  change: "changed", reason: "source_replaced", context: publisher_context)

# From an authorized worker, using the same tenant/account scope:
lifecycle.consume(id: "policy-change-812", context: worker_context)
```

The source event ID must be stable and unique within the scope. An identical
retry is idempotent; changing the source reference, digest or reason under the
same ID conflicts. `record` requires `record` authorization. `consume`
requires `consume` authorization, Journal read/write authorization, and
Consolidation `invalidate` authorization. The two services must use the same
database pool. A delivery marker and affected memory revisions commit together;
an exception leaves the event pending for retry. Use
`Journal#pending_event_ids` to discover pending `source_lifecycle:` IDs and
route them to this consumer. Keep that worker bounded and tenant scoped.

`change: "deleted"` has the same immediate retrieval effect as `changed`:
affected active heads become stale. `Consolidation#current` also revalidates
source bytes, version, freshness and authorization on every access, so a missed
event cannot turn old content into a fresh result. Historical revisions and
candidate quotes remain in the Journal; invalidation does **not** erase them.
Restrict historical reads and apply an application-owned retention or deletion
policy to source archives and Journal content. Do not delete immutable records
without preserving the receipt/tombstone semantics required for idempotency
and audit. This API deliberately does not perform physical deletion.

The host must emit the event after its source transaction commits, retain a
durable source-change queue, and retry when Journal is unavailable. There is a
gap between source commit and `record` unless the host places an intent in its
own transaction. The retrieval recheck limits incorrect reads during that gap;
the host outbox closes the delivery gap. The source digest records identity,
not a source body, and the reason should be a short code without private data.
