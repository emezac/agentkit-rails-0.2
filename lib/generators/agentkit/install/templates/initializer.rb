# frozen_string_literal: true

# The installer loads agentkit/engine from config/application.rb. Requiring an
# engine for the first time from this initializer is too late for Rails to add
# its models, rake tasks and migrations.
unless defined?(Agentkit::Engine)
  raise LoadError,
        "AgentKit must be loaded from config/application.rb. Add require \"agentkit\" and " \
        "require \"agentkit/engine\" before the application class."
end

Agentkit.configure do |config|
  config.domain_name    = "<%= Rails.application.class.module_parent_name %>"
  config.primary_entity = :entity
  config.multi_tenant   = false

  # ─── Models ────────────────────────────────────────────────────────────────
  config.llm.adapter = :ruby_llm     # :ruby_llm | :openai_compatible | :fake
  config.llm.profiles[:default] = Agentkit::ModelProfile.new(model: "claude-sonnet-4-6")
  config.llm.profiles[:fast]    = Agentkit::ModelProfile.new(model: "claude-haiku-4-5-20251001",
                                                             temperature: 0.2)
  config.llm.profiles[:complex] = Agentkit::ModelProfile.new(model: "claude-opus-4-6",
                                                             fallback: :default)

  # ─── Memory: storing and vectorising are two decisions ─────────────────────
  # level:  :off | :log | :keyword | :hybrid | :semantic | :full
  #   :keyword gives real retrieval with ZERO provider calls.
  config.memory.level = :hybrid
  # policy: :never | :immediate | :batched | :lazy | :on_promotion | :sampled | :manual
  #   :on_promotion only embeds what gets promoted (insights, repeatedly
  #   recalled, high importance) — usually an order of magnitude cheaper.
  config.memory.embedding.policy = :on_promotion
  config.memory.embedding.dedupe = true
  config.memory.query.cache      = true
  # Named lifecycle policies. `:keep` is the backwards-compatible default;
  # opt memory types or individual writes into finite retention explicitly.
  config.memory.retention.default_policy = :keep
  config.memory.retention.policies = {
    keep: nil,
    ephemeral: 7.days.to_i,
    standard: 90.days.to_i,
    durable: nil
  }
  # config.memory.retention.by_type = { observation: :standard, scenario: :ephemeral }
  # config.memory.budget.embeddings_per_day = { tenant: 5_000 }
  # config.memory.budget.on_exceeded = :degrade   # keep serving in keyword mode

  # ─── Human in the loop ─────────────────────────────────────────────────────
  config.hitl.level = :strict        # :strict | :advisory | :silent

  # Idempotency keys are durable in 0.4.1. Retain suggestion rows for the full
  # retry-safety horizon promised by your application.

  # ─── Audit: prompt capture is opt-in ───────────────────────────────────────
  config.audit.prompt_preview_chars = 0
  config.audit.failure_mode = :best_effort # :best_effort | :required
  config.audit.active_key_id = ENV.fetch("AGENTKIT_AUDIT_KEY_ID", "primary")
  config.audit.signing_keys = {
    config.audit.active_key_id => ENV.fetch("AGENTKIT_AUDIT_KEY")
  }

  # ─── Governed actions ─────────────────────────────────────────────────────
  config.actions.queue = :agentkit_actions
  config.watchtower.enabled = true

  # ─── Graph retrieval: opt-in, bounded and authorized before traversal ─────
  config.team_memory.graph_enabled = false
  # config.team_memory.graph_allowed_roots = [Rails.root.join("app").to_s]
  config.team_memory.graph_max_nodes = 2_000
  config.team_memory.graph_max_edges = 10_000
  config.team_memory.graph_max_hops = 3
  config.team_memory.graph_max_degree = 100
  config.team_memory.graph_max_iterations = 100
  config.team_memory.graph_wall_time_ms = 250

  # ─── Adaptive exploration: opt-in, replay-first, never auto-promotes ───────
  config.exploration.enabled = false
  config.exploration.max_rounds = 8
  config.exploration.replay_max_rounds = 32
  config.exploration.max_parallelism = 4
  config.exploration.max_nodes = 64
  config.exploration.default_beta = 0.6
  config.exploration.min_replay_coverage = 0.8
  config.exploration.holdout_fraction = 0.2
  # Keep this stable; changing it reassigns historical worlds.
  config.exploration.holdout_seed = ENV.fetch("AGENTKIT_EXPLORATION_HOLDOUT_SEED", "agentkit-0.8")
  config.exploration.min_training_worlds = 5
  config.exploration.min_holdout_worlds = 5
  config.exploration.bootstrap_samples = 2_000
  config.exploration.confidence_level = 0.95
  config.exploration.min_score_improvement = 0.0
  config.exploration.pareto_epsilon = 1e-9
  config.exploration.attempt_stale_after = 300
  config.exploration.resume_lease = 300
  config.exploration.execution = :local # :distributed uses Active Job
  config.exploration.queue = :agentkit_exploration
  config.exploration.daily_world_limit = nil
  config.exploration.daily_attempt_limit = nil
  config.exploration.quota_retention_days = 90
  # config.exploration.quota_resolver = ->(scope) {
  #   scope.tenant_key == "account:enterprise" ? { daily_world_limit: 100 } : {}
  # }

  # ─── Console: disabled in every environment until both hooks are set ──────
  config.console.enabled = false
  # config.console.principal_resolver = -> { current_user }
  # config.console.guard = ->(principal) { principal.admin? }
  # config.console.payload_guard = ->(principal) { principal.security_admin? }

  # ─── Telemetry: on from day 0, otherwise the factory has nothing to read ───
  config.telemetry.enabled  = true
  config.telemetry.backends = [:db]

  # ─── Factory: observe only until you have data ─────────────────────────────
  config.factory.mode = :observe     # :observe | :suggest | :auto_n1 | :auto_n1_n2
end

# What happens when a suggestion is approved. v0.1 had no such hook, so every
# project monkeypatched an after_commit onto the suggestion model.
# Agentkit::HITL.on("my_suggestion_type") { |s| MyService.call(s.payload) }

# Capabilities register on every code load, so edits under app/capabilities/
# take effect without a restart in development.
# Rails.application.config.to_prepare { ExampleCapability.register_all }
