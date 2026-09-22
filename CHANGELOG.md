# Changelog

## 1.0.0 — 2026-09-19

### Added

- Durable promotion dossiers for significant Adaptive Exploration holdout
  recommendations, with bounded evidence snapshots and deterministic digests.
- Explicit approve, reject and rollback transitions, tenant/account scope,
  optimistic locking, idempotent submission and mandatory audit persistence.
- Declarative policy bindings carrying stable name/version/digest, originating
  review id and monotonic generation. Rollback restores the previous binding.
- Governed review controls in `/agentkit/exploration`, plus a stable readiness
  report and dry-run-first `agentkit:exploration_maintenance` task.
- Migration `022_add_exploration_promotion_governance` and configurable daily
  quota-ledger retention (`quota_retention_days`, default 90).

### Changed

- The exploration dashboard is now an operator control surface for promotion
  reviews in addition to its 0.9 execution and quota visibility.
- `agentkit:doctor` validates promotion tables/indexes and reports pending
  reviews and active declarative bindings.
- Public package version and Adaptive Exploration API contract are now 1.0.

### Security

- Submission fails closed unless the recommendation carries a significant,
  matching two-policy holdout comparison produced for human review.
- Approval never registers code or mutates the policy registry. Rejection and
  rollback require a human reason; every accepted transition requires a
  durable audit write in the same store transaction.
- Dashboard mutations inherit console authorization, CSRF protection, tenant
  context, CSP and no-store caching. Superseded approvals cannot be rolled back
  over a newer active binding.

### Compatibility

- Migration 022 is additive. Existing worlds, replays, quotas and 0.9 local or
  distributed execution remain compatible.
- Applications must explicitly submit a recommendation and explicitly consume
  a declarative binding; there is no automatic promotion in 1.0.

## 0.9.0 — 2026-09-19

### Added

- Active Job delivery for registry-backed exploration worlds, with durable
  `queued` state, explicit scope propagation and duplicate-safe world leases.
- Immutable generator manifests, matching the evaluator provenance contract,
  so workers fail closed when code changes without a version bump.
- Atomic UTC daily world and attempt quotas with idempotent reservation keys,
  global defaults and tenant-specific resolver overrides.
- A read-only `/agentkit/exploration` operations dashboard for world/attempt
  states, safe provenance and quota consumption.
- Migration `021_add_distributed_exploration_and_quotas` and expanded doctor
  checks for distributed indexes, quota ledgers and operational backlog.

### Changed

- Online worlds now persist their generator manifest. A distributed worker
  resolves policy, generator and evaluator by stable registry identity.
- Exhausting attempt capacity closes a valid partial world with
  `quota_exhausted`; exhausting world capacity rejects admission before work.

### Security

- Distributed jobs carry only a world id and explicit tenant scope. Raw
  objectives, generated candidates and executable closures never enter the
  queue payload or dashboard.
- Quota accounting is transactionally serialized and idempotent under job
  redelivery. The dashboard inherits the console's fail-closed authorization,
  tenant boundary, CSP and `Cache-Control: no-store` headers.

### Compatibility

- Local execution remains the default. Existing 0.8 replay worlds stay valid;
  only new distributed worlds require registered generator provenance.

## 0.8.0 — 2026-09-19

### Added

- Deterministic paired percentile-bootstrap comparisons over identical replay
  worlds, including confidence intervals, standard error, minimum effect and a
  reproducible seed digest.
- Multiobjective Pareto frontiers over attained quality, probe count and replay
  rounds instead of treating a single scalar reward as sufficient evidence.
- Stable hash-based holdout assignment plus explicit curated holdouts, with
  disjointness checks and assignment/history digests.
- Training/holdout readiness checks in `agentkit:doctor` and configurable
  sample, confidence, effect, coverage and Pareto thresholds.

### Changed

- `Exploration.recommend` selects one candidate on training evidence, then
  compares only that candidate with the incumbent on untouched holdout worlds.
  A review recommendation now requires holdout coverage, Pareto validity and a
  confidence interval above `min_score_improvement`.

### Security

- Holdout outcomes never participate in candidate selection, and insufficient
  datasets do not expose holdout evaluations as diagnostics.
- Statistical evidence remains an advisory N3 recommendation. 0.8.0 cannot
  register, deploy or auto-promote a policy.

### Compatibility

- No migration is required. Existing replay worlds remain valid; callers that
  need the former point-estimate behavior can still use `evaluate`, while
  `recommend` now fails closed until training and holdout minima are met.

## 0.7.1 — 2026-09-19

### Added

- Durable per-round checkpoints and tenant-scoped attempt records with stable
  idempotency keys, explicit state transitions and resumable running worlds.
- Versioned evaluator registry with immutable source/schema/normalization
  manifests persisted alongside every world.
- Replay support metrics (`decision_coverage`, unsupported actions/decisions)
  and a configurable coverage gate for N3 policy recommendations.
- Expiring per-world resume leases, stale-attempt detection and an explicit
  `reconcile_attempt!` path for executions whose outcome is unknown.
- Migrations `019_harden_agentkit_exploration` and
  `020_add_agentkit_exploration_world_leases`.

### Security

- A claimed attempt is never retried implicitly after an interruption. Fresh
  attempts are treated as active; stale attempts become `execution_unknown`
  and require an audited operator reconciliation.
- Concurrent resume workers fail closed under a durable lease. Evaluator output
  is schema-validated before it can enter a checkpoint, and raw reconciliation
  artifacts are reduced to SHA-256 digests.
- Replay recommendations remain advisory and never auto-promote a policy.

### Compatibility

- Existing callable evaluators plus `evaluator_id` continue to work. Registered
  evaluators and resumable execution are additive; exploration remains opt-in.

## 0.7.0 — 2026-09-17

### Added

- Opt-in adaptive exploration with bounded online discovery trees, deterministic
  `CONTINUE(parent)` actions, real batch concurrency and durable tenant-scoped
  replay worlds.
- Prefix-only offline replay that reveals recorded children without calling the
  generator or evaluator, plus the quality − probe cost + parallelism objective.
- Deterministic portfolio policy balancing new roots, promising refinements and
  at most one repairable failure per batch. Beta is fixed within an episode.
- Fixed-history policy evaluation, incumbent-preserving N3 recommendations,
  beta sweeps and conservative cross-cycle beta planning.
- Migration `018_create_agentkit_exploration_worlds`, bounded/redacted
  diagnostics and low-cardinality online/replay telemetry.

### Security

- Server settings cap rounds, workers, nodes, policies, replay rounds and stored
  diagnostics; request arguments can only lower those limits.
- Policies receive a frozen revealed-prefix view, never hidden outcomes. Illegal,
  duplicate and over-wide actions fail closed.
- AgentKit does not evaluate generated policy source or auto-promote replay
  winners. Policy changes remain reviewed Factory N3 interventions.

### Compatibility

- Adaptive exploration is disabled by default. Existing agents, flows, Factory,
  graph retrieval and stores retain their 0.6 behavior.

## 0.6.0 — 2026-09-17

### Added

- Tenant-scoped normalized graph snapshots for Wiki, CodeGraph and RAG chunks,
  with canonical digests, lifecycle/provenance fields and additive migration
  `017_create_agentkit_graph_snapshots`.
- Deterministic Wiki graph building with Unicode title normalization,
  unresolved-link diagnostics and cycle reporting; CodeGraph now uses Ripper's
  Ruby AST and enforces canonical roots, symlink rejection and file-size limits.
- Bounded Personalized PageRank over a subgraph authorized before adjacency is
  constructed. Direction, damping, edge multipliers, hops, nodes, edges,
  iterations and wall time all have server-side limits.
- Opt-in `RAG.retrieve(strategy: :hybrid_graph)` with three-rank RRF, opaque
  supporting paths, deterministic fallback and graph activation telemetry.
- Flow topology annotations, deterministic compiler warnings,
  `Flow.explain_plan`, and measured transition/rework/topology metrics.
- Principal-scoped ephemeral `ActivationTrace` visualization, an experimental
  wave feature flag, and a labeled evaluation corpus/command reporting
  Recall@K, nDCG@K, MRR, latency, convergence, traversal and hidden inference.

### Compatibility

- Graph retrieval remains opt-in. Existing Wiki keyword search and RAG hybrid
  retrieval retain their default behavior.
- Retrieved graph content remains untrusted evidence. Traces contain a query
  digest and opaque path aliases, never the raw query or hidden node ids.

## 0.5.0 — 2026-09-17

### Added

- Durable governed actions with separate proposal, decision, execution attempt,
  outbox and observed outcome records, plus a static retry/reconciliation state
  machine and portable redacted receipts.
- Capability contract v2: closed input/output schemas, effects, permissions,
  idempotency and reconciliation requirements, execution limits, versions and
  explicit per-adapter exposure.
- Audit schema v2 with per-tenant sequence locking, SHA-256 hash chaining, HMAC
  signatures, verification and retention checkpoints.
- Watchtower invariant scans with stable, tenant-scoped finding fingerprints.
- Optional `agentkit-mcp` package tested against official Ruby MCP SDK 1.5.1; its
  registry is allow-list only and shares policy/action enforcement with A2A.
- PostgreSQL coverage for audit-chain concurrency and transactional outbox
  recovery.

### Changed

- A2A capability calls now use `Agentkit::Policy` and `Agentkit::Actions`.
  Mutating work returns `action:<public_id>` tasks; no transport has a private
  authorization path.
- A2A and MCP publish only capabilities with explicit `expose` declarations.
- Legacy `inputs` declarations remain executable but emit a deprecation warning;
  new capabilities should use closed JSON schemas.

## 0.4.1 — Unreleased

### Security

- HITL decisions now use a database row lock/atomic transition. Only one
  approve/reject operation can consume a pending suggestion, and the decision
  ledger is written in the same transaction.
- Approval and execution are separate phases. Side effects run through
  `ExecuteSuggestionJob`; terminal failures are visible as
  `execution_failed` or `execution_unknown` instead of being swallowed.
- Idempotency keys are durable and unique by
  `(tenant_key, operation_namespace, idempotency_key)`. Reuse with different
  arguments raises `Agentkit::IdempotencyConflict`.
- Audit payload redaction is recursive, prompt capture is opt-in, and required
  audit writes can fail closed with `failure_mode = :required`.
- The web console is disabled by default in every environment and requires an
  explicit principal resolver and authorization guard. Responses now carry
  no-store, CSP, frame, referrer and MIME-sniffing protections.
- Unexpected A2A errors return a correlation id and a generic message instead
  of exposing exception classes or messages.

### Added

- Migration `015_harden_agentkit_hitl_and_audit.rb` and PostgreSQL concurrency
  coverage for approve/approve and approve/reject races.
- `bundle exec rake release:verify` builds the gem, emits a SHA-256 checksum
  and SPDX 2.3 SBOM, and verifies installation from the built artifact.

## 0.4.0 — 2026-08-26

### Added

- Added an A2A 1.0 HTTP+JSON adapter with the standard Agent Card discovery
  route, version negotiation, Message/Task/Artifact projection and task states
  for completed, failed, input-required and authorization-required work.
- Added tenant-aware Agent Cards and task isolation through `tenant_resolver`,
  `card_builder` and the standard `AgentInterface.tenant` routing hint.
- Added standard bearer security declarations and configurable Agent Card
  signing and verification using RS256 JWS over canonical JSON.
- Added an outbound A2A 1.0 client with signature policy and HTTPS enforcement.
- Added tenant-scoped durable storage for A2A tasks so polling survives process
  restarts and works consistently across web workers.

### Compatibility

- The pre-1.0 JSON-RPC dispatcher and `/.well-known/agent.json` remain enabled
  by default. Set `config.a2a.legacy = false` after all existing peers migrate.

## 0.3.2 — Unreleased

### Security

- Removed the caller-controlled A2A `force_sync` HITL bypass. Approvals bind to
  the canonical arguments digest, enforce separation of duties, revalidate
  policy and preconditions, and execute idempotently.
- Added mandatory `Agentkit::Scope` boundaries across Memory, HITL, Flow,
  artifacts, Audit, Factory, controllers, reports and background jobs.
- Tenantized Factory findings, experiments, golden cases and cycle runs with
  compound uniqueness constraints and tenant-specific advisory locks.
- Imported skills are validated, provenance-stamped and quarantined until a
  separate HITL activation decision.
- Team Memory ACL now denies unknown or incomplete visibility configurations.

### Fixed

- RAG no longer invents random query vectors. Missing embeddings degrade
  deterministically to BM25 and emit `rag.retrieval.degraded`.
- Retrieved evidence is escaped, digest-labelled, size-bounded and explicitly
  presented to the model as untrusted data.
- Added a reproducible `bundle exec rake verify` command and CI compatibility
  matrix. The suite contains 310 examples.

## 0.3.1 — Unreleased

### Fixed

- Restored Ruby 3.1/3.2 parser compatibility for the in-memory HITL store.
- Added tenant-scoped persistence and lookup for RAG corpora, teams, assets,
  wiki pages, code symbols, and asset bindings.
- Added migration `010_add_agentkit_tenancy.rb` so an existing 0.3 database can
  gain tenant boundaries without replaying already-applied migrations.
- Rejects unscoped RAG and Team Memory operations when `multi_tenant` is enabled.
- Rejects assets linked to a team owned by another tenant.
- Validates RAG embedding dimensions before PostgreSQL attempts to store them.
- Generator failures are no longer mislabeled as harmless duplicate migrations.
- Corrected migration numbering and removed a merge-conflict artifact from the documentation.

## 0.3.0 — Native RAG & Team Memory Hub

### Added

- **Épica 1 — RAG Nativo (`Agentkit::RAG`)**:
  - Full retrieval-augmented generation engine: BM25, Sliding Window / Semantic / Sentence Chunker, Indexer, Retriever (Vector + BM25 + RRF fusion), and Pipeline with streaming support.
  - `ChapterChunker` and `CorpusSlice` for chapter/heading-based document partitioning.
  - `KnowledgeStore` with `:memory` (singleton) and `:active_record` backends, metadata filtering, and pgvector + tsvector schema (`008_create_agentkit_knowledge.rb`).
  - `Agentkit::RAG::AgentConcern` mixed into `Agentkit::Agent`: `use_knowledge`, `rag_retrieve`, `rag_index_slice`, `rag_generate`, `rag_context`.

- **Épica 1.5 — Orquestación RAG Distribuida**:
  - `Agentkit::RAG::CoordinatorFlow`: multi-step map/reduce flow for partitioning large PDFs (90MB+), parallel chapter indexing, chapter analysis, and bibliography reduction.
  - Agents: `PDFChapterChunkerAgent`, `ChapterIndexerAgent`, `ChapterAnalystAgent`, `BibliographyReportAgent`.
  - `MapNode#max_concurrency` now accepts lambdas for dynamic worker scaling.
  - Fixed `Result.capture` double-wrapping bug (`wrap(yield)` instead of `ok(yield)`).

- **Épica 2 — Team Memory Hub (`Agentkit::TeamMemory`)**:
  - TencentDB Agent Memory implementation: team-level governance for ChatMemory, Skill, Wiki, and CodeGraph assets.
  - ACL engine supporting `private`, `team`, `restricted`, `agent`, and `public` visibility rules.
  - Wiki engine with `[[Wikilink]]` extraction, page management, and keyword search.
  - CodeGraph static analysis engine extracting Ruby classes, modules, methods, callers, callees, and impact analysis.
  - `SkillExtractor` for auto-generating executable skills from chat transcripts.
  - `LayeredPipeline` (L0 raw → L1 atoms → L2 scenes → L3 persona/skills).
  - `TeamMemory::AgentConcern` mixed into `Agent`: `join_team`, `share_skill`, `load_team_assets`, `equip_team_assets`.
  - Migration `009_create_agentkit_team_memory.rb` and ActiveRecord models (`TeamRecord`, `MemoryAssetRecord`, `WikiPageRecord`, `CodeSymbolRecord`, `AssetBindingRecord`).
  - Web dashboard in `/agentkit/team_memory`.

- **Épica 3 — Mejoras de Memoria Avanzada**:
  - `Memory::Layers` helpers for L0-L3 memory progression.
  - `Memory::ColdStart` importer for historical JSON/JSONL transcripts.
  - `Memory::CustomPrompts` for per-tenant/team template overrides.
  - `Memory.recall(since:, until:)` time-window filtering.
  - Interactive `mem:` chat commands (`mem:status`, `mem:sync`, `mem:skill`, `mem:help`) in `Agentkit::Chat.say`.
  - `SkillExport` for packaging skills as `SKILL.md` + `tools.json` bundles and importing them.

- **Épica 4 — Generadores Rails**:
  - `rails g agentkit:rag` for scaffolded RAG configuration & migration.
  - `rails g agentkit:team_memory` for scaffolded Team Memory Hub & migration.
  - Migration `010_add_agentkit_tenancy.rb` upgrades existing 0.3 installations with tenant-scoped RAG and Team Memory records.
### Fixed

- Added the conventional `agentkit-rails` Bundler entrypoint. It explicitly
  loads the engine after Rails even when `agentkit` was already cached by a
  plain-Ruby process earlier in boot.
- The install generator now puts `require "agentkit"` and
  `require "agentkit/engine"` in `config/application.rb`, after the Rails
  framework requires and before the application class. Loading the engine from
  an initializer was too late to register its models and
  `agentkit:install:migrations` task.

## 0.2.1 — 2026-07-24

### Fixed — eleven defects found by the integration suite

None of these were visible to the 166-example unit suite: the in-memory
adapters are more forgiving than Postgres (they accept `nil` in a NOT NULL
column, register steps on the `Run` for free and never lose state on restart),
and nothing was booting Rails at all. Five of them had already shipped and were
caught by piloting the gem on a real application; the other six surfaced the
first time `spec/dummy` started.

- **Engine never loaded** when `require "agentkit"` ran before Rails existed.
  The hook checked for `Rails::Engine`, which is only defined once
  `rails/engine` has been required — a boot-order dependency.
- **Rake tasks loaded from the wrong path**, so `bin/rails` refused to start.
- **Zeitwerk could not eager-load `A2AController`**: the file name camelizes to
  `A2aController`, so production boot raised and the engine's `a2a#rpc` route
  pointed at a constant that did not exist.
- **`ActiveJob::Base` resolved inside `module Agentkit`** — every job class
  needed `::ActiveJob::Base`.
- **The ActiveRecord flow store never registered steps on the `Run`**, leaving
  `run.step`, `children_of` and the fan-out replay blind. This broke the entire
  async path under ActiveRecord while the in-memory store hid it.
- **The SQL barrier decrement did not refresh the caller's copy**, so a sync
  fan-out read a stale `pending_count` and suspended forever.
- **`usage: nil` written into a NOT NULL column** by any step that did not call
  the LLM.
- **`update_all` bypassed type casting**, so a pgvector column could never be
  written ("can't cast Array"). Vectors are now encoded explicitly, which also
  works when the `vector` OID is not registered on the connection.
- **Migration 001 wrapped everything in a blanket `rescue`**, which swallowed
  the real error and left the transaction aborted so every later migration
  failed with a misleading message. Capability is now checked, not rescued.
- **A dimensionless `vector` column** could not be indexed; the column is
  created with explicit SQL.
- **`NotImplementedError` is not a `StandardError`**, so a queue adapter that
  cannot schedule a future job took down `HITL.suggest!` instead of just losing
  the auto-apply timer.

### Added

- `spec/dummy`: a real Rails app with Postgres and pgvector, plus 37
  integration examples covering engine boot, Zeitwerk eager-load, the three
  ActiveRecord stores, the async barrier under out-of-order and duplicated
  delivery, artifact offloading and resumption from the database alone.
- `Flow::Coder` now encodes the run input too, so a domain record reaches a
  worker as a record rather than a Hash of attributes.
- `on_error: :continue` on a step: a non-essential failure is recorded and
  tolerated instead of unwinding the run.
- `HITL::Stores::ActiveRecordStore` and `ActiveRecordLedger`, wired by the
  engine. Suggestions no longer live in a process-local Hash, where a restart
  dropped every pending approval.

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
