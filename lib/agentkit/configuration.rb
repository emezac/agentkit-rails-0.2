# frozen_string_literal: true

require_relative "settings"

module Agentkit
  # ─── LLM ─────────────────────────────────────────────────────────────────────

  # One entry per routing profile. `fallback` names another profile to try when
  # this one fails permanently or its circuit is open.
  class ModelProfile < Settings
    setting :model
    setting :provider,    default: :ruby_llm
    setting :temperature
    setting :max_tokens
    setting :timeout,     default: 60
    setting :fallback
    setting :price_in     # USD per 1M input tokens  (nil => look up in Pricing)
    setting :price_out    # USD per 1M output tokens

    # Per-profile credentials, so two OpenAI-compatible gateways can coexist.
    #
    # Without these the adapter called `RubyLLM.configure` once, globally, and
    # memoised it: configuring a second gateway clobbered the first. A fallback
    # chain that crossed providers was therefore impossible — which is exactly
    # what you need when one provider's quota runs out.
    setting :api_base
    setting :api_key
  end

  class LLMSettings < Settings
    setting :adapter,        default: :ruby_llm      # :ruby_llm | :openai_compatible | :fake
    setting :api_base                                 # for OpenAI-compatible providers (Qwen/DashScope)
    setting :anthropic_api_key, default: -> { ENV.fetch("ANTHROPIC_API_KEY", nil) }
    setting :openai_api_key,    default: -> { ENV.fetch("OPENAI_API_KEY", nil) }
    setting :google_api_key,    default: -> { ENV.fetch("GOOGLE_API_KEY", nil) }

    setting :retries,        default: 3
    setting :backoff_base,   default: 0.5            # seconds; exponential with jitter
    setting :timeout,        default: 60
    setting :schema_retries, default: 1              # re-asks when output fails the schema
    setting :cache,          default: true           # prompt caching hint (stable block first)

    # Circuit breaker per provider.
    setting :breaker_threshold, default: 5           # consecutive failures to open
    setting :breaker_cooldown,  default: 30          # seconds before half-open

    # Profiles. `Agentkit.config.llm.profiles[:complex]` → ModelProfile
    setting :profiles, default: lambda {
      {
        fast:    ModelProfile.new(model: "claude-haiku-4-5-20251001", temperature: 0.2),
        default: ModelProfile.new(model: "claude-sonnet-4-6"),
        complex: ModelProfile.new(model: "claude-opus-4-6", fallback: :default),
        code:    ModelProfile.new(model: "claude-sonnet-4-6"),
        vision:  ModelProfile.new(model: "claude-sonnet-4-6")
      }
    }
  end

  # ─── Memory ──────────────────────────────────────────────────────────────────

  class PromotionSettings < Settings
    setting :types,          default: -> { %w[insight pattern summary] }
    setting :min_importance, default: 0.6
    setting :min_recalls,    default: 2
  end

  class EmbeddingSettings < Settings
    # :never | :immediate | :batched | :lazy | :on_promotion | :sampled | :manual
    setting :policy,      default: :on_promotion,
                          in: %i[never immediate batched lazy on_promotion sampled manual]
    setting :model,       default: "text-embedding-3-small"
    setting :dimensions,  default: 1536
    setting :batch_size,  default: 64
    setting :flush_every, default: 300               # seconds
    setting :dedupe,      default: true              # exact, by content_hash
    setting :near_dupe,   default: nil               # 0.0..1.0 lexical threshold, nil = off
    setting :sample_rate, default: 0.1               # for policy :sampled
    setting :tiers,       default: -> { {} }         # { observation: {model:, dimensions:} }
    setting :gc,          default: -> { { archived: true, superseded: true, after: 7 * 86_400 } }
  end

  class QuerySettings < Settings
    setting :cache,      default: true
    setting :cache_ttl,  default: 3600
    setting :cache_size, default: 500
    setting :normalize,  default: true
  end

  class MemoryBudgetSettings < Settings
    setting :embeddings_per_day, default: -> { {} }  # { tenant: 5_000, global: 50_000 }
    setting :on_exceeded, default: :degrade, in: %i[degrade queue drop raise]
    setting :degrade_to,  default: :keyword
    setting :alert_at,    default: 0.8
  end

  class DreamingSettings < Settings
    setting :clustering, default: :batch_embed, in: %i[batch_embed lexical llm]
    setting :threshold,  default: 0.25
    setting :min_cluster, default: 2
    setting :min_recalls, default: 2
    setting :supersede_sources, default: true        # non-destructive consolidation
    setting :cron,       default: "0 3 * * *"
  end

  class ImaginationSettings < Settings
    setting :backend,     default: :local, in: %i[local maas]
    setting :divergence,  default: 0.65
    setting :min_sources, default: 3
    setting :max_sources, default: 12
    setting :min_ideas,   default: 3
    setting :max_ideas,   default: 6
    setting :incubate_temperature, default: 0.9
    setting :verify_temperature,   default: 0.1
    setting :gates, default: -> { { originality: 0.4, innovation: 0.5, relevance: 0.4, confidence: 0.5 } }
    setting :ttl,   default: 30 * 86_400
  end

  class MemorySettings < Settings
    # The ladder that replaces v0.1's all-or-nothing feature flag.
    setting :level, default: :hybrid, in: %i[off log keyword hybrid semantic full]
    setting :store, default: :active_record          # :active_record | :memory (tests)
    setting :default_k,          default: 5
    setting :default_threshold,  default: 0.3
    setting :hybrid_candidates,  default: 200        # SQL prefilter width before vector rerank
    setting :per_tenant                              # ->(tenant) { {...} }

    group :embedding, EmbeddingSettings
    group :promotion, PromotionSettings
    group :query,     QuerySettings
    group :budget,    MemoryBudgetSettings
    group :dreaming,  DreamingSettings
    group :imagination, ImaginationSettings

    # Does this level ever produce vectors?
    def vectors?
      %i[hybrid semantic full].include?(level)
    end

    def writes?
      level != :off
    end
  end

  # ─── HITL ────────────────────────────────────────────────────────────────────

  class HITLSettings < Settings
    setting :level, default: :strict, in: %i[strict advisory silent]
    setting :auto_apply_delay, default: 24 * 3600
    # Per suggestion_type overrides: { "follow_up" => 300 }
    setting :auto_apply_delays, default: -> { {} }
    setting :require_rejection_code, default: true
    setting :rejection_codes, default: lambda {
      %i[wrong_target bad_timing wrong_tone factually_wrong already_done
         not_valuable too_risky missing_context]
    }
    setting :dedupe_window, default: 24 * 3600       # idempotency_key reuse window
  end

  # ─── Flow ────────────────────────────────────────────────────────────────────

  class FlowSettings < Settings
    setting :store,   default: :active_record, in: %i[active_record memory]
    setting :executor, default: :async, in: %i[async sync]
    # How async work is delivered: :active_job in production, :inline when no
    # job backend is loaded, :test for a queue a spec drains by hand.
    setting :dispatcher, default: :active_job, in: %i[active_job inline test]
    setting :queue,   default: :agentkit_flows
    setting :max_inline_payload, default: 64 * 1024
    setting :default_step_timeout, default: 300
    setting :default_join_timeout, default: 600
    setting :sync_threads, default: false            # parallel via threads in sync mode
    setting :persist_in_sync, default: true
  end

  # ─── Telemetry ───────────────────────────────────────────────────────────────

  class TelemetrySettings < Settings
    setting :enabled,  default: true
    setting :backends, default: -> { [:db] }         # :db | :memory | :otel | :statsd | :log
    setting :flush_every,   default: 5               # seconds
    setting :flush_size,    default: 200             # events
    setting :retention_days, default: 90
    # Per-event sampling: { "memory.recall" => 0.1 }. Missing key => 1.0
    setting :sampling, default: -> { {} }
  end

  # ─── A2A ─────────────────────────────────────────────────────────────────────

  class A2ASettings < Settings
    setting :enabled,     default: false
    setting :name                                  # defaults to domain_name
    setting :description
    setting :version,     default: "1.0.0"
    setting :base_url,    default: -> { ENV.fetch("AGENTKIT_BASE_URL", "http://localhost:3000") }
    setting :mount_path,  default: "/agentkit/a2a"
    setting :secret_key,  default: -> { ENV.fetch("AGENTKIT_A2A_KEY", nil) }
    setting :key_resolver                          # ->(key) { Account.find_by(a2a_key: key) }
    # Which capabilities are visible to peers. nil = all eligible ones.
    setting :expose
    setting :hide,         default: -> { [] }
    setting :expose_memory, default: false         # opening memory to peers is a decision
    setting :allow_registration, default: false    # self-service key issuing
  end

  # ─── Audit ───────────────────────────────────────────────────────────────────

  # Deliberately NOT part of telemetry: audit is never sampled and does not
  # expire on its own. Compliance-sensitive domains have to be able to prove
  # what an agent did and on what evidence.
  class AuditSettings < Settings
    setting :enabled, default: true
    setting :store,   default: :active_record, in: %i[active_record memory]
    setting :prompt_preview_chars, default: 500   # 0 disables prompt capture
    setting :redact, default: lambda {
      [
        /\b[\w.+-]+@[\w-]+\.[\w.-]+\b/,                       # emails
        /\b(?:\d[ -]*?){13,16}\b/,                            # card-like numbers
        /\b(?:sk|pk|api)[-_][A-Za-z0-9]{16,}\b/               # api keys
      ]
    }
    setting :retention_days, default: nil          # nil = keep forever
  end

  # ─── Factory ─────────────────────────────────────────────────────────────────

  class FactorySettings < Settings
    # :observe accumulates statistics only — safe default for day 0.
    setting :mode, default: :observe, in: %i[observe suggest auto_n1 auto_n1_n2]
    setting :cycle, default: -> { { diagnose: "0 6 * * 1", report: :weekly } }
    setting :finding_cooldown, default: 7 * 86_400
    setting :resolve_after_clean_cycles, default: 2
    setting :baseline_window, default: 28 * 86_400
    setting :golden_set, default: lambda {
      { capture: %i[rejected edited], sample: 0.2, max_per_agent: 200, freeze_after_review: true }
    }
    setting :promotion, default: lambda {
      { min_samples: 60, min_effect: 0.05, significance: 0.90,
        golden_set_gate: :no_regression, min_duration: 3 * 86_400, cost_guard: 1.10 }
    }
    setting :guardrails, default: lambda {
      { max_cost_increase: 0.30, max_acceptance_drop: 0.10 }
    }
  end

  # ─── Chat / proposals ────────────────────────────────────────────────────────

  class ChatSettings < Settings
    setting :enabled,        default: false
    setting :max_proposals,  default: 3
    setting :min_score,      default: 0.55
    setting :require_why,    default: true
    setting :cooldown,       default: 7 * 86_400     # per (capability, subject)
    setting :suppress_after_rejections, default: 2
    setting :imperative_mode, default: :propose, in: %i[propose execute]
  end

  # ─── Root ────────────────────────────────────────────────────────────────────

  class Configuration < Settings
    setting :domain_name,    default: "AgentKit App"
    setting :primary_entity, default: :entity

    # The host's own models, for the user_id / account_id columns the kernel
    # tables already carry. 0.1 declared these associations; 0.2 dropped them,
    # which turned `create!(user: someone)` into an UnknownAttributeError in
    # every app that upgraded. Resolved lazily by name, so an app without a
    # User or Account model is unaffected until it asks for one.
    setting :user_class,    default: "User"
    setting :account_class, default: "Account"
    setting :multi_tenant,   default: false
    setting :tenant_resolver                          # ->(context) { tenant }
    setting :features,       default: -> { [] }

    group :llm,       LLMSettings
    group :memory,    MemorySettings
    group :hitl,      HITLSettings
    group :flow,      FlowSettings
    group :telemetry, TelemetrySettings
    group :audit,     AuditSettings
    group :a2a,       A2ASettings
    group :factory,   FactorySettings
    group :chat,      ChatSettings

    # v0.1 compatibility: `config.a2a_enabled = true` still works.
    def a2a_enabled = a2a.enabled
    def a2a_secret_key = a2a.secret_key

    def a2a_enabled=(value)
      a2a.enabled = value
    end

    def a2a_secret_key=(value)
      a2a.secret_key = value
    end

    def feature?(name)
      Array(features).map(&:to_sym).include?(name.to_sym)
    end

    def strict_hitl?   = hitl.level == :strict
    def advisory_hitl? = hitl.level == :advisory
    def silent_hitl?   = hitl.level == :silent

    # Resolve the effective configuration for a tenant, applying
    # `memory.per_tenant` if defined. Copy-on-write: the global config is never
    # mutated, so a request for tenant A can never leak into tenant B.
    def for_tenant(tenant)
      return self if tenant.nil? || memory.per_tenant.nil?

      overrides = memory.per_tenant.call(tenant) || {}
      with(memory: overrides)
    end
  end
end
