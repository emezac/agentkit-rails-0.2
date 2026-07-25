# Changelog

## 0.2.0 — Kernel rewrite

Rebuilt from the diagnosis of six production applications running 0.1.

### Fixed (bugs that forced five forks of the gem)

- **B1/B2 — `chat` could not run.** `RubyLLM.chat(model:, messages:, system:)` is not
  the gem's API; five projects patched the same method. The adapter is now verified
  against the real gem and token accounting probes the shapes ruby_llm actually
  exposes.
- **B3 — `AutoApplySuggestionJob.perform_in`** is Sidekiq, not ActiveJob. Scheduling
  is a port; the engine supplies `set(wait:).perform_later`.
- **B4 — `discard_on` with a block** was incompatible with the Sidekiq/ActiveJob
  wrapper. Jobs rescue inside `perform`.
- **B5 — quadratic triggers.** `trigger_agent` installed one callback per
  declaration and each callback re-iterated every trigger: three role bots meant
  nine agent runs. One callback per event now, with a regression spec.
- **B6 — SQL injection surface.** The vector was interpolated into `ORDER BY`.
  Bind parameters everywhere.
- **B7 — hardcoded `User` constant** in the worker, which broke API-key hosts.
- **B8 — `on: :destroy, async: true` never worked.** The job loaded a deleted row
  and swallowed the error; destroy triggers carry a snapshot now.
- Agent callbacks moved from `after_save` to `after_commit` (async agents could
  read uncommitted rows).
- **`agent_log` no longer discards non-numeric payload.** An early v2 draft
  routed it through telemetry only, which kept the numbers and silently dropped
  the prompt preview, the model and every string field — a regression against
  v0.1's audit log. It now writes the complete record to the audit store and
  the numeric measures to telemetry.
- **`LLM.complete(model: nil)`** raised "no model profile could serve the
  request" because `Array(nil)` is empty; it falls back to `:default`.

### Added

- **Flow engine** — `step`, `parallel`, `join` (atomic barrier), `map`/`reduce`,
  `loop_until`, `race`, `human_gate`, `sub_flow`, `on_error`, `compensate`.
  Sync and async executors over one definition; resumable, idempotent runs.
- **Async executor, complete** — each fan-out branch is its own job carrying
  everything it needs in its step row, so it runs on any worker. The run
  SUSPENDS at a join or a human gate instead of blocking a worker, and the
  branch that decrements the barrier to zero enqueues the continuation.
  `Flow::Coder` round-trips payloads between jobs (records travel as references
  and are reloaded; oversized payloads offload to `agentkit_artifacts`).
  `Flow::Dispatcher` is a port with `:active_job`, `:inline` and `:test`
  implementations — the test queue drains in FIFO, LIFO or random order and can
  replay every job twice, which is how the barrier and the idempotency are
  actually proven rather than asserted. Join timeouts are one scheduled job per
  join with three policies: `:continue_with_partial` cancels stragglers and
  moves on, `:compensate` unwinds the saga through the normal failure path, and
  `:fail` stops the run.
- **Memory policy layer** — six retrieval levels, seven embedding policies,
  content-hash dedupe, query-vector cache, per-tenant budget with degradation,
  vector GC, partial HNSW index, cost estimator.
- **Cognition processors** — Dreaming (on demand, dry-run, non-destructive,
  three clustering strategies), Summarizer (five strategies, token budget,
  cache), Imagination (three phases, local backend, ontological firewall).
- **HITL v2** — apply handlers, closed rejection taxonomy, idempotency,
  human gates that resume a flow, decision ledger with quality metrics.
- **Telemetry** — kernel probes, buffered batch writes, sampling, descriptive
  statistics (p50/p95/p99, histograms), two-proportion significance testing.
- **Audit trail and XAI traces** — `agentkit_audit_logs` succeeds v0.1's
  `agentkit_agent_logs` with the full payload, a redacted prompt preview and
  correlation ids (`trace_id`, `run_id`, `step_key`). Append-only: no update or
  destroy path, retention is an explicit prune. Kept deliberately separate from
  telemetry, which is sampled and expires. `agentkit_traces` /
  `agentkit_trace_phases` persist the phase-by-phase reasoning of dreaming,
  summarizing, imagination and councils in one shared format, so
  `Audit.provenance(memory)` can answer why a memory exists and which sources
  produced it.
- **Factory** — deterministic detectors, experiments with deterministic
  bucketing and guardrails, statistical promotion, golden-set capture,
  N1–N5 intervention ladder, Markdown cycle report.
- **Proposal-first chat** — Setup, Capability, ProposalEngine, IntentResolver,
  capability gaps, learned suppression.
- **LLM layer** — structured output with re-ask, function calling, retries,
  circuit breaker, fallback chains, real cost accounting, `:fake` adapter,
  OpenAI-compatible adapter that self-registers Qwen/DashScope models.
- **Versioned prompts** with deterministic canary and exclusions.
- `rails g agentkit:install --with-chat`, `rails agentkit:doctor`,
  `agentkit:estimate_embeddings`, `agentkit:factory_report`.

### Changed

- `Agentkit::ApplicationAgent` is an alias of `Agentkit::Agent`; `chat`,
  `memorize!`, `recall!`, `suggest!`, `build_context` and `domain_context` keep
  their v0.1 signatures.
- `agent_log` emits a buffered telemetry event instead of a synchronous INSERT
  per call (`tres` had disabled it entirely for that reason).
- Consolidation marks sources `superseded` instead of `archived` — reversible.
- Configuration is nested and copy-on-write, with unknown keys accepted instead
  of requiring the class to be reopened.

- **A2A protocol, rebuilt** — the agent card is *generated from the Capability
  registry* instead of being a hardcoded list, which is why v0.1's version had
  zero uses: it advertised things the app could not do. JSON-RPC 2.0 with
  constant-time `X-A2A-Key` comparison and `/.well-known/agent.json` (from
  `tres`), optional self-service registration (from `totallook`), an outbound
  `A2A::Client` with approval polling, and per-capability risk in the card.
  A remote invocation lands on the same rail as a local proposal — Capability →
  Flow → HITL → audit — so an irreversible action is parked for a human and the
  caller gets a task id to poll. Memory exposure is opt-in and never returns
  imagined scenarios.
- **Console** — HITL inbox with Turbo Streams (approve / edit / reject with a
  taxonomy code, live updates), flow run timeline showing the fan-out barrier
  and its branches, factory dashboard with per-agent quality and economics, and
  on-demand cognition buttons. Provenance view walks an imagined suggestion back
  to its three-phase trace and source memories.

### Removed

- `CodeGeneration#apply!`, which wrote generated Ruby straight to the
  application's filesystem. Level-5 factory changes emit a reviewable patch.
- The old `SkillRegistry` autoloader that used `require` and broke code reloading.
