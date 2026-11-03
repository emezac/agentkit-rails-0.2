# Operator workflows

Migration `027_create_agentkit_operator_workflows` adds four optional pieces to
the Rails engine. They reuse the existing Flow, HITL and Memory engines; no
computer-use tools, generic connectors or implicit approvals are added.

## Routines

Configure `console.enabled`, `console.guard` and `console.principal_resolver`
before opening `/agentkit/routines`. The form accepts a **registered Flow**,
JSON input and one of: one-time ISO 8601 execution, interval of at least 60
seconds, or daily local time in an IANA time zone. Programmatic creation uses
the same scoped API:

```ruby
Agentkit::Routines.create!(
  name: "Morning brief", flow_name: "MorningBriefFlow",
  schedule_kind: "daily", time_zone: "America/Mexico_City",
  hour: 8, minute: 0, input: { team_id: 7 }, context: operator_context
)
```

The engine registers one `RoutineTickJob` per minute when `sidekiq-cron` is
available. Otherwise schedule that job in the host. Each due time has a unique
occurrence receipt; duplicate ticks and duplicate dispatch jobs do not create
another Flow run. Missed intervals/days coalesce to one occurrence and the
next future time. A spring-forward nonexistent wall time is skipped; a
fall-back repeated wall time fires once. The Flow's own human gates still
govern sensitive steps.

If a worker dies after claiming an occurrence but before recording the Flow
run ID, it remains `dispatching` and appears in `/agentkit/attention` after
five minutes. Do **not** blindly retry it: a Flow might already have been
enqueued. Reconcile the run first. Failed dispatches also appear in the
attention inbox. This favors no duplicate side effects over automatic retry
of an ambiguous dispatch.

## Attention inbox

`/agentkit/attention` combines scoped pending suggestions, failed or
human-waiting runs, routine issues, memory proposals and operations
escalations. It is a read-only triage view; decisions continue through each
subsystem's existing guarded action. The console is off by default.

## Async delegation

`Agentkit::Delegations.dispatch!(flow: MyFlow, input: { ... }, context: ctx)`
returns a durable Flow run receipt. `Delegations.receipt(run_id, context: ctx)`
reads status/output/error only within the same tenant/account. The target must
be a registered Flow. For a coordinator that must resume automatically after
multiple delegates, use Flow's existing `parallel` and `join` nodes; this
receipt API is for out-of-band hand-offs and does not invent a second agent
execution or approval path.

## Reviewable memory

`Agentkit::MemoryReviews.propose!(content: ..., tags: ..., context: ctx)`
persists a proposal but **does not** make it recallable. A guarded operator
approves or rejects it at `/agentkit/memory_proposals`. Approval writes through
the existing Memory policy. Undo archives the resulting memory instead of
deleting it. Proposed, approved/rejected and undone transitions are recorded
in an append-only review journal. Every lookup is tenant/account scoped.
