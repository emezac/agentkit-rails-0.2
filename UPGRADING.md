# Upgrading 0.5.0 → 0.6.0

Install and run migration `017_create_agentkit_graph_snapshots`. It adds graph
snapshot/node/edge tables and provenance fields to existing code symbols. The
migration is additive; existing Wiki, CodeGraph and RAG APIs keep working.

Graph retrieval is opt-in. Build a validated snapshot, then request the new
strategy explicitly:

```ruby
wiki = Agentkit::TeamMemory::Wiki.build_snapshot("EngineeringWiki")

Agentkit::RAG.retrieve(
  "cómo se valida un reembolso",
  corpus_name: "engineering",
  strategy: :hybrid_graph,
  graph: "EngineeringWiki",
  explain: true
)
```

Configure server-side bounds rather than accepting arbitrary values from a
caller:

```ruby
config.team_memory.graph_enabled = true
config.team_memory.graph_allowed_roots = [Rails.root.join("app").to_s]
config.team_memory.graph_max_nodes = 2_000
config.team_memory.graph_max_edges = 10_000
config.team_memory.graph_max_hops = 3
config.team_memory.graph_wall_time_ms = 250
```

Flow annotations are optional but make unsafe topology visible at boot and in
`MyFlow.explain_plan`. A `side_effecting` parallel/map node now requires an
explicit `idempotency_key` annotation.

Run the included labeled evaluation before making graph retrieval a host-level
default. The command reports measured values and refuses to run without a
dataset:

```bash
DATASET=config/graph_retrieval_eval.json bundle exec rake agentkit:graph_eval
bundle exec rake verify
```

The activation viewer is protected by the existing console guard. Publish an
already-computed trace with `TeamMemory::Visualization.publish(result.trace,
context:)` and open `/agentkit/team_memory/activation/:id`. It cannot change
ranking or authorization state.

---

# Upgrading 0.4.1 → 0.5.0

Install and run migration `016_create_agentkit_governed_actions`. It creates
the action proposal/decision/attempt/outbox/outcome tables, audit chain heads,
Watchtower findings and adds audit-v2 columns.

Configure an audit HMAC key before booting with the ActiveRecord audit store:

```ruby
config.audit.active_key_id = ENV.fetch("AGENTKIT_AUDIT_KEY_ID", "primary")
config.audit.signing_keys = {
  config.audit.active_key_id => ENV.fetch("AGENTKIT_AUDIT_KEY")
}
```

Migrate externally visible capabilities to contract v2. `inputs` remains as a
deprecated compatibility surface, but it is not a closed protocol contract.

```ruby
cap.input_schema(type: "object", properties: { id: { type: "integer" } },
                 required: ["id"], additionalProperties: false)
cap.output_schema(type: "object", properties: {}, additionalProperties: false)
cap.effect :internal
cap.required_permission "records.write"
cap.expose :a2a, mode: :propose
```

Exposure is now deny-by-default. Add `cap.expose :a2a` for every intended A2A
skill. Install `agentkit-mcp` separately and add `cap.expose :mcp`; merely
registering a capability never publishes it.

A2A authorization tasks now use ids such as `action:<public_id>`, not HITL
suggestion ids. Approve or reject them through `Agentkit::Actions.decide!` with
an authenticated principal. The requester cannot approve its own action.

External capabilities must require a durable idempotency key and define a
required reconciler. A timeout becomes `execution_unknown`, not `execution_failed`; reconcile it
before retrying so an ambiguous side effect is never repeated blindly.

After migration run:

```bash
rails agentkit:audit_verify TENANT=__global__
rails agentkit:watchtower
bundle exec rake verify
```

---

# Upgrading 0.4.0 → 0.4.1

Install and run migration `015_harden_agentkit_hitl_and_audit`. It adds the
execution lifecycle fields and a partial unique index for durable HITL
idempotency. Historical duplicate keys are preserved under stable `:legacy:`
namespaces instead of being deleted.

Approvals now move through `pending → approved → executing → executed`. Queue
dispatch failures become `execution_failed`; failures after a worker has
claimed the operation become `execution_unknown`. Code that previously tested
for the persisted values `accepted` or `auto_applied` should use
`suggestion.approved?` or the new lifecycle states.

Idempotency keys no longer expire after `hitl.dedupe_window`. Supply a stable
`operation_namespace:` when a key could be reused by independent operations.
Reusing the same tuple with different canonical arguments raises
`Agentkit::IdempotencyConflict`. Rows must be retained for at least as long as
the host promises retry safety; deleting them also deletes that guarantee.

Prompt previews are now disabled by default. Opt in only where the data policy
allows it, and select whether audit storage may fail open:

```ruby
config.audit.prompt_preview_chars = 0
config.audit.failure_mode = :best_effort # or :required
```

The AgentKit console is also disabled by default, including development and
test. Enabling it requires both an authenticated principal and a fail-closed
authorization policy:

```ruby
config.console.enabled = true
config.console.principal_resolver = -> { current_user }
config.console.guard = ->(principal) { principal.admin? }
# Without this optional permission, payloads are recursively redacted.
config.console.payload_guard = ->(principal) { principal.security_admin? }
```

In multi-tenant applications, the mounted controller must also expose a
non-null `current_account`; otherwise console access is rejected.

Release maintainers should run `bundle exec rake release:verify`. It executes
the reproducible suite, builds the gem, emits `.sha256` and `.spdx.json`
artifacts, and installs the generated gem into an isolated temporary directory.

---

# Upgrading 0.3.2 → 0.4.0

AgentKit 0.4 adds A2A 1.0 without removing the 0.3 JSON-RPC API. New peers
should discover `/.well-known/agent-card.json` and use the HTTP+JSON endpoints
under `/agentkit/a2a`.

Install and run migration `014_create_agentkit_a2a_tasks`. It provides durable,
tenant-scoped task polling across restarts and multiple Rails workers.

For multi-tenant applications, resolve the account from the Rails request and
optionally customize domain fields in the generated card:

```ruby
config.a2a.tenant_resolver = ->(request) { Vendor.find_by(subdomain: request.subdomains.first) }
config.a2a.card_builder = lambda do |card, context|
  card.merge(iconUrl: context.account.logo_url)
end
```

Use `security_schemes` and `security_requirements` to advertise the host's real
authentication mechanism. The default declares HTTP Bearer authentication;
`X-A2A-Key` remains accepted for legacy callers.

Card signatures are optional. To publish an RS256 signature:

```ruby
config.a2a.signing_key = ENV.fetch("AGENTKIT_A2A_SIGNING_KEY_PEM")
config.a2a.signing_key_id = "provider-2026-01"
config.a2a.signing_jwks_url = "https://agents.example/.well-known/jwks.json"
```

Outbound verification accepts `:disabled`, `:if_present` (the default), or
`:required`. Populate `trusted_keys` with `kid => public_key` entries. AgentKit
does not automatically trust arbitrary `jku` URLs.

Once every peer uses A2A 1.0, disable the old discovery route with
`config.a2a.legacy = false`.

---

# Upgrading 0.3.1 → 0.3.2

Install and run migrations `011`, `012` and `013`. Historical unscoped rows are
assigned to `__global__`; the rollback is intentionally irreversible because
merging tenant security boundaries is unsafe.

With `multi_tenant = true`, all AgentKit reads, mutations, reports and jobs now
require an `Agentkit::Context` or serialized `Agentkit::Scope`. Queue producers
must include the scope passed by the kernel; legacy unscoped jobs fail closed
and should be discarded or re-enqueued with their original tenant.

Skill import now returns a quarantined Team Memory asset. Approve the generated
`skill_activation` suggestion before expecting the skill in `SkillRegistry`.

`force_sync` only expresses transport waiting preference and never bypasses
approval. A2A mutation callers should always provide an `idempotency_key`.

---

# Upgrading 0.2.1 → 0.3.1

## Required steps

1. Point the application at `agentkit-rails`, version `~> 0.3.1`.
2. Install the engine migrations and run them:

   ```bash
   bin/rails agentkit:install:migrations
   bin/rails db:migrate
   ```

3. Confirm that migration `010_add_agentkit_tenancy.rb` ran. It adds
   `tenant_key` and `account_id` to RAG and Team Memory tables and replaces
   global uniqueness constraints with tenant-scoped ones.
4. Applications with more than one tenant must enable strict scoping:

   ```ruby
   Agentkit.configure do |config|
     config.multi_tenant = true
   end
   ```

5. Run every RAG and Team Memory operation inside an `Agentkit::Context`, or
   pass `tenant_key:` explicitly. Unscoped access raises `ConfigurationError`
   when strict scoping is enabled.

   ```ruby
   context = Agentkit::Context.new(account: current_account)

   Agentkit.with_context(context) do
     Agentkit::RAG.retrieve("refund policy", corpus_name: "handbook")
     Agentkit::TeamMemory.load_assets(team: "Operations")
   end
   ```

## Database security

The engine now enforces tenant scope in its Ruby and ActiveRecord adapters.
Applications that use PostgreSQL Row-Level Security should add their own RLS
policies for the six new tables, using the same session tenant mechanism as the
host application:

- `agentkit_knowledge_chunks`
- `agentkit_teams`
- `agentkit_memory_assets`
- `agentkit_wiki_pages`
- `agentkit_code_symbols`
- `agentkit_asset_bindings`

AgentKit deliberately does not install a generic RLS policy because host
applications differ in how they place the current tenant in a PostgreSQL
session variable. RLS remains a second line of defence in addition to the
engine's mandatory scopes.

## Embedding dimensions

The default RAG schema uses `vector(1536)`. If the configured embedding model
returns another size, create a host migration for the desired vector dimension
and set:

```ruby
config.rag.embedding_dimensions = 3072
```

AgentKit now raises a clear configuration error before writing a vector whose
size does not match this setting.

## Compatibility notes

- Existing Agent, Flow, HITL, Memory, Audit and Factory APIs remain compatible
  with 0.2.1.
- Team names are unique per tenant instead of globally.
- RAG chunk identifiers are unique per tenant and corpus.
- `RAG.drop_corpus` only removes the current tenant's corpus.

---

# Upgrading 0.1 → 0.2

## TL;DR for the six existing applications

1. Delete `vendor/gems/agentkit-rails-0.1.0` and the patches on top of it. Every
   fix those forks carried is upstream now.
2. Point the Gemfile at `gem "agentkit-rails", "~> 0.2"`.
3. Run the new migrations. The old tables are read-compatible; new columns are
   additive.
4. Replace the initializer's flat keys with the nested ones (table below).
5. Nothing in `app/agents/` has to change: the v0.1 agent surface is preserved.

## Engine boot for existing applications

If `rails agentkit:install:migrations` is missing or the classes under the
engine's `app/models` do not autoload, AgentKit is being required for the first
time from `config/initializers/agentkit.rb`. That happens after Rails has
already collected its engines.

Run the installer again, or add these lines to `config/application.rb` after
the Rails framework requires and before the application class:

```ruby
require "agentkit"
require "agentkit/engine"
```

The operation is idempotent. Once those lines are present, remove any
`require "agentkit"` left in the initializer.

## Configuration mapping

| 0.1 | 0.2 |
|---|---|
| `config.llm_default_model = "x"` | `config.llm.profiles[:default] = Agentkit::ModelProfile.new(model: "x")` |
| `config.llm_fast_model` / `_complex` / `_code` / `_vision` | `config.llm.profiles[:fast]` / `[:complex]` / `[:code]` / `[:vision]` |
| `config.embedding_model` | `config.memory.embedding.model` |
| `config.embedding_batch_size` (never read in 0.1) | `config.memory.embedding.batch_size` |
| `config.hitl_level` | `config.hitl.level` |
| `config.dreaming_cron` / `_threshold` | `config.memory.dreaming.cron` / `.threshold` |
| `config.auto_consolidate` | `config.memory.dreaming.supersede_sources` |
| `config.features = [:rag]` | `config.memory.level = :hybrid` (see below) |
| `config.anthropic_api_key` etc. | `config.llm.anthropic_api_key` etc. |

Unknown keys no longer raise: `config.my_custom_thing = 1` is kept, so the
`Agentkit::Configuration.class_eval` monkeypatch that `dos/maas` needed can go.

## Memory: pick a level instead of a boolean

`totallook` turned memory off entirely with an env var and lost its audit trail.
That trade-off no longer exists:

```ruby
config.memory.level            = :keyword       # search with zero API calls
config.memory.embedding.policy = :never
```

Recommended starting point for an app that was on `features: [:rag]`:

```ruby
config.memory.level            = :hybrid
config.memory.embedding.policy = :on_promotion
config.memory.embedding.dedupe = true
```

Check what it will cost before enabling anything:

```bash
POLICY=on_promotion rails agentkit:estimate_embeddings
```

## Deprecated, still working

- `Agentkit::ApplicationAgent` → alias of `Agentkit::Agent`.
- `Agentkit::AgentTriggerable` → alias of `Agentkit::Triggerable`.
- `Agentkit::ModelRouter.resolve(:complex)` still returns a model string.
- `agent_log(event:, payload:)` still exists; it emits telemetry now.

## Removed, with a replacement

| Removed | Replacement |
|---|---|
| `Agentkit::MemoryEngine.store/search/cluster_raw` | `Agentkit::Memory.store/recall`, `Cognition.run(:dreaming)` |
| `Agentkit::HITLEngine.suggest!` | `Agentkit::HITL.suggest!` (same keywords) |
| `Agentkit::DreamingJob` | `Agentkit::CognitionJob.perform_later("dreaming")` |
| `Agentkit::AgentWorkerJob` | `Agentkit::TriggerJob` |
| `CodeGeneration#apply!` | `Agentkit::Factory.patch!` (emits a PR, never writes) |
| `Agentkit::A2aController` | out of scope; keep your own controller |

## Things you can now delete from your app

- `astra`: `Astra::CreditGuard` (→ usage events + budget), `AgentPromptVersion`
  (→ `Agentkit::Prompt` with canary).
- `maas`: the `after_commit` monkeypatch on `Agentkit::AgentSuggestion`
  (→ `Agentkit::HITL.on`), the `perform_in` patch, the rewritten jobs.
- `tres`: the `hitl_engine.rb` edit, the `agent_log` override, `parse_json`.
- `totallook`: the `memorize!` override (→ `memory_policy`), the manual Qwen
  model registration (→ `adapter: :openai_compatible`).
- `cuatro`: the random-embedding stub (→ `level: :keyword` in dev, deterministic
  fake in test).
