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
