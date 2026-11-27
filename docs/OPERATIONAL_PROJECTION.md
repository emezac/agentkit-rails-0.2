# Operational projection

`Harness::OperationalProjection` creates a compact, read-only view of one
supervised unattended run, its shared budget and its escalation. It joins
existing authorized service APIs. It does not query their tables or grant
execution, approval or deployment permission.

```ruby
view = Agentkit::Harness::OperationalProjection.new(
  runs: unattended_runs,
  budgets: shared_budgets,
  escalations: operations_escalations,
  authorize: ->(action, ids, context) {
    OperationsPolicy.can_read_run_and_budget?(ids, context)
  }
)
report = view.fetch(run_id: "night-42", budget_id: "billing-window-7",
  context: authenticated_operator_context)
```

The host must bind `budget_id` to `run_id` in its own authorized registry. The
projection authorizer runs before and after source reads, and each underlying
source enforces its own tenant and read policy. A missing run returns `nil`; a
missing budget or mismatched escalation fails closed. Do not give this read
policy to a model as a tool without the host's normal data-access checks.

The result includes goal and required gate identifiers, current run status and
reason, artifact and contract digests, commit SHA, completed call count, usage
completeness, root budget usage/limits/remaining capacity, escalation status,
and machine-readable blockers. It omits lease tokens, worker claims, raw
verification diagnostics, prompts, provider messages and escalation targets.
An explicit `authorizes: false` applies even to a `verified` result.

`point_in_time: false` means the three sources were read sequentially. A
contract digest recheck detects a changed run contract, but concurrent budget
settlements or acknowledgements can still occur between reads. Refresh the
view for current decisions. The projection never marks missing usage as zero
and reports a separate `usage:unknown` blocker. A budget overrun and an open
or exhausted escalation remain distinct from a run's terminal status.

The Rails console applies its existing authentication guard. The host owns
pagination, polling, alerts, links to retained evidence, and authorization for
any button that changes state. Keep
write actions on the existing service APIs. The host also owns the mapping
between a budget window and the run, and must maintain it through retries and
revisions. This opt-in projection requires migrations 024, 026, 031 and 033
for the backing services; it introduces no new table or automatic job.

## Rails console page

The optional read-only page is `GET /agentkit/operations/:id`. It uses the
existing disabled-by-default console authentication and adds no write action.
Configure a trusted resolver that binds run ID to budget ID in application
storage and calls the projection; the browser never supplies a budget ID:

```ruby
config.console.operational_view = lambda do |run_id, context|
  budget_id = RunBudgetBinding.authorized_for(run_id, context)&.budget_id
  next nil unless budget_id
  operational_projection.fetch(run_id: run_id, budget_id: budget_id, context: context)
end
```

The resolver must enforce current host policy. A missing resolver or binding
returns 404. The page renders only the projection's allowlisted summary fields;
it does not display raw lease tokens, worker claims or escalation targets.
The usual console guard and principal resolver are still required. There is
no automatic index because cross-run discovery needs an application-owned
authorized query.
