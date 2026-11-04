# Mandated tasks and source events

This optional Rails workflow binds a host-authorized request to one durable Flow run. It reuses Flow, ToolContract and the existing attention inbox. It adds no model calls, background router or automatic permission grants. Install migration 028 before using `TaskEvents`.

## Authorize a delegation

Configure a deterministic callback in **every web and worker process**. The host must authenticate the requester and check its current policy on every phase. A callback that is absent, fails, or returns anything other than `true` denies execution. The stored policy version is evidence of admission; the callback must decide whether it remains valid.

```ruby
Agentkit::TaskMandate.authorizer = lambda do |mandate, phase, context|
  TaskPolicy.allowed?(requester: mandate.fetch("requester"),
    flow: mandate.fetch("flow"), policy_version: mandate.fetch("policy_version"),
    phase: phase, tenant_key: context.tenant_key)
end

mandate = Agentkit::TaskMandate.issue(
  flow: "ResearchFlow", source: "github", resource: "org/repo",
  thread: "issue:42", policy_version: TaskPolicy.version,
  allowed_tools: %w[search_documents], context: authenticated_context
)
receipt = Agentkit::Delegations.dispatch!(flow: ResearchFlow,
  input: { issue_id: 42 }, context: authenticated_context, mandate: mandate)
Agentkit::TaskEvents.subscribe!(run_id: receipt.run_id, context: authenticated_context)
```

The mandate is recorded in the Flow run, bound to its flow, tenant/account, requester, source and original thread. The worker rechecks it before advancing a run or queued branch. `Flow.resume` also rechecks it. On denial, an async run waits for human attention and executes no new step. The host can restore authorization and resume it. The allowed-tool list limits read tools exposed through `ToolCatalog` and called through `ToolContract`; other domain effects still require their existing Capability/Actions/HITL gates. Legacy delegations without a mandate keep their existing behavior.

## Route a known event

The host authenticates the webhook or connector **before** calling `ingest!` and supplies a source-policy callback. Use an identity containing provider, resource and thread, not a bare issue number. The event body is untrusted task data; it cannot change the mandate. A unique source event ID deduplicates retries, and reusing that ID with different content raises a conflict.

```ruby
route = Agentkit::TaskEvents.ingest!(
  source: "github", resource: "org/repo", thread: "issue:42",
  event_id: "comment:9", payload: { kind: "comment", text: "CI failed" },
  context: connector_context,
  authorize: ->(source, resource, thread, id, ctx) {
    SourcePolicy.allowed?(source, resource, thread, id, ctx)
  }
)
if route
  Agentkit::TaskEvents.pending(run_id: route.fetch(:run_id),
    context: authenticated_worker_context).each do |event|
    # The host passes this data to the task's worker with event[:event_key] as
    # its stable delivery key, then marks it consumed after acceptance.
  end
end
```

This API returns the existing run ID without a routing model call. The host owns worker wake-up and event delivery. Delivery is **at least once** if the host crashes after acceptance and before `mark_consumed!`; the recipient must deduplicate by `event_key` or reconcile before retry. New external requests still require separate host admission. Only one live task may subscribe to a given scoped source/resource/thread. Finished runs do not receive new events.

`TaskEvents.metrics(run_id:, context:)` returns recorded Flow cost, elapsed time, completed human-gate count and event counts. A completed Flow is not proof that the business outcome was verified; the host records that outcome separately. Schedule `TaskEvents.prune_consumed!(before:, context:, authorize:)` to remove consumed event bodies after the host's retention period. The event key and payload digest remain as small tombstones so an old retry cannot be accepted again. Pending events remain until explicitly handled.
