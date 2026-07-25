# Upgrading 0.1 → 0.2

## TL;DR for the six existing applications

1. Delete `vendor/gems/agentkit-rails-0.1.0` and the patches on top of it. Every
   fix those forks carried is upstream now.
2. Point the Gemfile at `gem "agentkit-rails", "~> 0.2"`.
3. Run the new migrations. The old tables are read-compatible; new columns are
   additive.
4. Replace the initializer's flat keys with the nested ones (table below).
5. Nothing in `app/agents/` has to change: the v0.1 agent surface is preserved.

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
