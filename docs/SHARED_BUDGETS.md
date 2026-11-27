# Shared hierarchical budgets

`Agentkit::SharedBudget` is an opt-in durable admission port for work launched
by a trusted Rails host. It combines cost, token and concurrency limits in one
PostgreSQL row lock. Install migrations 024 (Journal) and 033 (budget tables);
the Journal and budget records must use the same database pool.

## Contract

The host defines one immutable billing window and a rooted tree. Each node has
limits for `cost_microusd`, `tokens` and `concurrency`. Paths have zero to four
segments and must include every ancestor. A reservation at a leaf charges all
its ancestors exactly once. This permits tenant, project, run and agent limits
in one admission decision. A different budget ID is a different billing window;
the host controls who may create one and prevents overlapping windows that would
evade an organization limit.

```ruby
budget = Agentkit::SharedBudget.new(
  journal: Agentkit::Knowledge::Journal.new(authorize: journal_policy),
  authorize: ->(action, request, context) { BudgetPolicy.allow?(action, request, context) }
)

nodes = [[], ["project-7"], ["project-7", "run-42"],
         ["project-7", "run-42", "agent-a"]].map do |path|
  { path: path, limits: { cost_microusd: 5_000_000,
                          tokens: 200_000, concurrency: 2 } }
end

budget.define(id: "billing-2026-11", nodes: nodes,
  expires_at: (Time.now.utc + 86_400).iso8601(6), context: operator_context)

grant = budget.reserve(id: "billing-2026-11", key: "provider-call-123",
  path: %w[project-7 run-42 agent-a],
  amounts: { cost_microusd: 250_000, tokens: 8_000 },
  expires_at: (Time.now.utc + 60).iso8601(6), context: worker_context)
raise "duplicate launch" unless grant.fetch("newly_reserved")
```

`reserve` must be called outside a caller-owned transaction, before invoking a
provider or worker. Its reservation key is stable across retries. An identical
retry returns the existing receipt with `newly_reserved: false`; a changed
request fails. A caller must **not** execute work again for an existing key.
The host must enforce provider-side hard limits and terminate work at its
deadline. These database counters do not limit a provider's actual bill.

After a trusted measured result, call `settle` with exact nonnegative integer
usage and a source reference. A duplicate identical settlement is idempotent;
another value or source conflicts. Actual usage above the reservation is still
recorded and blocks subsequent admission until capacity permits. Charges are
never silently capped at a limit. A settlement frees one concurrency slot.

If the provider call fails or its usage is unavailable, call `unknown`. The
full reservation and concurrency slot remain held, even after expiry. A
separately authorized operator uses `settle(..., reconcile: true)` only after
checking authoritative provider usage. Expiry alone never refunds capacity.
Journal failures roll back the associated reserve/settle transaction.

## Applying it to existing subsystems

`run` wraps one host-controlled execution: it reserves, executes the supplied
block once, maps its measured result, settles, and marks exceptions unknown. It
does not redispatch an existing reservation. For `AgentLoop`, pass
`measure: Agentkit::SharedBudget.method(:loop_usage)`; this maps the loop's
measured USD and tokens into integer micro-USD and tokens. Missing or unpriced
calls are rejected as unknown and require reconciliation. Keep AgentLoop's
local `ExecutionBudget` as the per-call/loop guard; `SharedBudget` covers the
larger billing window.

Exploration probes and unattended workers can use the same `reserve`/`settle`
protocol at their trusted host boundary. Their existing internal quotas remain
independent until the host explicitly wraps their execution; merely defining
a shared budget does not automatically intercept those subsystems. Do not
double-reserve a provider call under two unrelated keys. Use a stable external
operation ID to associate accounting receipts with operational receipts.

## Host responsibilities and limits

Supply authenticated tenant and principal contexts and deny unknown policy
actions: `define`, `reserve`, `unknown`, `settle`, `reconcile`, `read`,
`read_reservation`. Recheck resource permissions on both initial admission and
replay. Restrict `define` and `reconcile` to trusted operators. A reconciliation
operator may differ from the original worker but remains in the same tenant.
Protect Journal kind `budget` with its own authorization policy. Receipt reads
include the original scope and evidence reference; restrict them accordingly.

The four path levels are names, not automatically validated against Rails
projects or runs. The host must map them to authorized resources and enforce
an organization-wide budget contract. Define immutable windows with explicit
deadlines and avoid overlapping active windows for the same spend source.
Budget counters are cumulative for a window. There is no automatic reset,
global billing sync, scheduler, process termination or provider reconciliation.
`fetch` and `reservation` expose read-only snapshots; `authorizes: false` makes
clear that a receipt is not a permission to execute.
