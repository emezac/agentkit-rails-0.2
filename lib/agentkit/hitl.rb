# frozen_string_literal: true

require_relative "hitl/ledger"
require_relative "hitl/stores"
require "digest"
require "json"

module Agentkit
  # Human-in-the-loop with a real apply step, a decision ledger and idempotency.
  #
  # Fixes carried over from v0.1:
  #   * `AutoApplySuggestionJob.perform_in` is a Sidekiq API, not ActiveJob —
  #     it raised in every project (`tres` edited the kernel, `dos/maas`
  #     monkeypatched the job). Scheduling now goes through a port.
  #   * Approving did nothing. MaaS had to reopen `Agentkit::AgentSuggestion`
  #     with an `after_commit` to actually apply an accepted suggestion. Now
  #     handlers are first-class: `HITL.on("type") { |s| ... }`.
  #   * `find_suggestion!` required a user, which broke API-key hosts.
  module HITL
    Suggestion = Struct.new(
      :id, :suggestion_type, :title, :description, :priority, :status, :source_agent,
      :payload, :suggestable, :user_id, :account_id, :tenant_key, :idempotency_key,
      :prompt_id, :prompt_version, :model, :created_at, :resolved_at, :expires_at,
      :run_id, :gate_key, :experiment_id, :experiment_arm, :metadata,
      keyword_init: true
    ) do
      def pending?  = status.to_s == "pending"
      def resolved? = %w[accepted rejected auto_applied expired].include?(status.to_s)
      def accepted? = %w[accepted auto_applied].include?(status.to_s)
      def approved? = accepted?
      def high_priority? = %w[high critical].include?(priority.to_s)
    end

    PRIORITIES = %w[low medium high critical].freeze

    class << self
      def ledger
        @ledger ||= Ledger.new
      end

      # Any object answering to []/[]=/values works. The Rails engine swaps in
      # an ActiveRecord-backed store with the same three methods.
      def store
        @store ||= Stores::InMemory.new
      end

      attr_writer :store, :ledger

      def handlers
        @handlers ||= Hash.new { |h, k| h[k] = [] }
      end

      def scheduler
        @scheduler ||= default_scheduler
      end

      attr_writer :scheduler

      def reset!
        @ledger    = Ledger.new
        @store     = Stores::InMemory.new
        @observers = []
        @handlers  = nil
        @seq       = 0
        @auto_approve = {}
        @gate_listeners = []
        self
      end

      # ─── Registration ────────────────────────────────────────────────────────

      # What should happen when a suggestion of this type is accepted.
      #
      #   Agentkit::HITL.on("council_recommendation") { |s| ApplyDecision.call(s) }
      def on(type, &block)
        handlers[type.to_s] << block
        block
      end

      # Flows subscribe here so an approval can resume a suspended run.
      def on_gate_resolved(&block)
        gate_listeners << block
        block
      end

      # Lifecycle observers (created / resolved). The Rails engine uses these to
      # push Turbo Stream updates; the kernel stays UI-agnostic.
      def observe(&block)
        observers << block
        block
      end

      def observers = @observers ||= []

      def notify(event, suggestion)
        observers.each do |o|
          o.call(event, suggestion)
        rescue StandardError => e
          Agentkit.logger&.warn("[AgentKit::HITL] observer failed: #{e.message}")
        end
      end

      def gate_listeners = @gate_listeners ||= []

      # ─── Create ──────────────────────────────────────────────────────────────

      def suggest!(type:, title:, description: nil, source_agent: nil, priority: "medium",
                   payload: {}, suggestable: nil, idempotency_key: nil, prompt_id: nil,
                   prompt_version: nil, model: nil, gate_key: nil, context: nil,
                   experiment_id: nil, experiment_arm: nil, metadata: {})
        ctx    = context || Context.resolve
        config = ctx.config.hitl
        assignment = if experiment_id
                       { experiment_id: experiment_id, experiment_arm: experiment_arm }
                     elsif prompt_id && prompt_version
                       Prompt.experiment_assignment(prompt_id, version: prompt_version, ctx: ctx)
                     else
                       {}
                     end

        if idempotency_key && (existing = find_by_idempotency(idempotency_key, config, ctx))
          Telemetry.emit("hitl.deduped", dims: { type: type.to_s, agent: source_agent })
          return existing
        end

        suggestion = Suggestion.new(
          suggestion_type: type.to_s, title: title, description: description,
          priority: priority.to_s, source_agent: source_agent, payload: payload || {},
          suggestable: suggestable, status: config.level == :silent ? "silenced" : "pending",
          user_id: id_of(ctx.user), account_id: id_of(ctx.account), tenant_key: ctx.tenant_key || "__global__",
          idempotency_key: idempotency_key, prompt_id: prompt_id, prompt_version: prompt_version,
          model: model, run_id: ctx.run_id, gate_key: gate_key, created_at: Time.now,
          experiment_id: assignment[:experiment_id], experiment_arm: assignment[:experiment_arm],
          metadata: metadata || {}
        )
        # The store assigns the id — the database in production, the sequence
        # in memory. Pre-assigning here would collide with real primary keys.
        store.insert(suggestion)

        Telemetry.emit("hitl.propose",
                       dims: { agent: source_agent, type: type.to_s, priority: priority.to_s,
                               level: config.level, prompt_id: prompt_id, prompt_version: prompt_version,
                               experiment_id: assignment[:experiment_id],
                               experiment_arm: assignment[:experiment_arm] },
                       measures: { count: 1 })

        schedule_auto_apply(suggestion, config) if config.level == :advisory
        notify(:created, suggestion)
        auto_decide(suggestion)
        suggestion
      end

      # ─── Resolve ─────────────────────────────────────────────────────────────

      def approve(id, actor: "human", final_payload: nil, mode: "human", scope: nil)
        suggestion = fetch!(id, scope: scope)
        raise HITLError, "Suggestion #{id} is already resolved" unless suggestion.pending?
        validate_approval!(suggestion, actor, final_payload)
        edited     = !final_payload.nil? && final_payload != suggestion.payload

        suggestion.status      = mode == "auto" ? "auto_applied" : "accepted"
        suggestion.resolved_at = Time.now
        suggestion.metadata = (suggestion.metadata || {}).merge("decision_actor" => actor.to_s)

        # Record BEFORE overwriting the payload: the ledger's edit distance is
        # the difference between what the agent proposed and what the human
        # actually approved, and that difference is the training signal.
        ledger.record(suggestion, decision: edited ? "edited" : "accepted",
                                  actor: actor, mode: mode, final_payload: final_payload)
        suggestion.payload = final_payload if edited
        store[suggestion.id] = suggestion
        run_handlers(suggestion)
        notify_gate(suggestion)
        notify(:resolved, suggestion)
        suggestion
      end

      def reject(id, actor: "human", code: nil, note: nil, mode: "human", scope: nil)
        suggestion = fetch!(id, scope: scope)
        raise HITLError, "Suggestion #{id} is already resolved" unless suggestion.pending?
        config     = Agentkit.config.hitl
        validate_code!(code, config)

        suggestion.status      = "rejected"
        suggestion.resolved_at = Time.now

        ledger.record(suggestion, decision: "rejected", actor: actor, mode: mode,
                                  rejection_code: code, rejection_note: note)
        store[suggestion.id] = suggestion
        notify_gate(suggestion)
        notify(:resolved, suggestion)
        suggestion
      end

      def snooze(id, until_time: nil, actor: "human")
        suggestion = fetch!(id)
        suggestion.status  = "snoozed"
        suggestion.expires_at = until_time || (Time.now + 86_400)
        store[suggestion.id] = suggestion
        suggestion
      end

      def expire!(id, actor: "system")
        suggestion = fetch!(id)
        suggestion.status = "expired"
        suggestion.resolved_at = Time.now
        ledger.record(suggestion, decision: "expired", actor: actor, mode: "auto")
        store[suggestion.id] = suggestion
        notify_gate(suggestion)
        suggestion
      end

      # ─── Query ───────────────────────────────────────────────────────────────

      def find(id, scope: nil)
        resolved_scope = Scope.resolve(scope)
        suggestion = store[id]
        resolved_scope.match?(suggestion) ? suggestion : nil
      end

      def fetch!(id, scope: nil)
        find(id, scope: scope) || raise(SuggestionNotFound, "Suggestion #{id} not found")
      end

      def pending(scope = {})
        resource_scope = Scope.resolve(scope)
        filters = scope.is_a?(Hash) ? scope : {}
        store.values.select do |s|
          s.pending? && resource_scope.match?(s) &&
            (filters[:type].nil?       || s.suggestion_type == filters[:type].to_s) &&
            (filters[:priority].nil?   || s.priority == filters[:priority].to_s)
        end.sort_by { |s| [-PRIORITIES.index(s.priority).to_i, s.created_at] }
      end

      def pending_count(scope = {}) = pending(scope).size

      def by_gate_key(key) = store.values.find { |s| s.gate_key == key }

      # ─── Test helpers ────────────────────────────────────────────────────────

      # Lets a spec drive a flow through a human_gate without a UI.
      def auto_approve!(type: nil, agent: nil)
        auto_approve[[type&.to_s, agent&.to_s]] = :approve
      end

      def auto_reject!(type: nil, agent: nil, code: :not_valuable)
        auto_approve[[type&.to_s, agent&.to_s]] = [:reject, code]
      end

      def auto_approve = @auto_approve ||= {}

      private

      def canonical_digest(payload)
        normalized = normalize_json(payload)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(normalized))}"
      end

      def normalize_json(value)
        case value
        when Hash then value.map { |k, v| [k.to_s, normalize_json(v)] }.sort.to_h
        when Array then value.map { |v| normalize_json(v) }
        else value
        end
      end

      def validate_approval!(suggestion, actor, final_payload)
        metadata = suggestion.metadata || {}
        requester = metadata["requester_principal"] || metadata[:requester_principal]
        if requester && requester.to_s == actor.to_s
          raise HITLError, "requester cannot approve its own proposal"
        end

        expected = metadata["arguments_digest"] || metadata[:arguments_digest]
        return unless expected

        candidate = final_payload || suggestion.payload
        actual = canonical_digest(candidate.reject { |k, _| k.to_s == "via" })
        raise HITLError, "approved payload does not match the proposed arguments digest" unless actual == expected
      end

      def find_by_idempotency(key, config, context)
        window = Time.now - config.dedupe_window
        tenant_key = context.tenant_key || "__global__"
        store.values.find do |s|
          s.idempotency_key == key && s.tenant_key.to_s == tenant_key.to_s && s.created_at >= window
        end
      end

      def validate_code!(code, config)
        return unless config.require_rejection_code
        return if code && Array(config.rejection_codes).map(&:to_s).include?(code.to_s)

        raise UnknownRejectionCode,
              "reject requires one of: #{Array(config.rejection_codes).join(', ')} (got #{code.inspect})"
      end

      def run_handlers(suggestion)
        handlers[suggestion.suggestion_type].each do |handler|
          handler.call(suggestion)
        rescue StandardError => e
          Telemetry.emit("hitl.handler_failed",
                         dims: { type: suggestion.suggestion_type, error_class: e.class.name })
          Agentkit.logger&.error("[AgentKit::HITL] handler for #{suggestion.suggestion_type}: #{e.message}")
        end
      end

      def notify_gate(suggestion)
        return if suggestion.gate_key.nil?

        gate_listeners.each { |l| l.call(suggestion) }
      end

      def auto_decide(suggestion)
        rule = auto_approve[[suggestion.suggestion_type, suggestion.source_agent]] ||
               auto_approve[[suggestion.suggestion_type, nil]] ||
               auto_approve[[nil, suggestion.source_agent]] ||
               auto_approve[[nil, nil]]
        return if rule.nil?

        if rule == :approve
          approve(suggestion.id, actor: "test:auto")
        else
          reject(suggestion.id, actor: "test:auto", code: rule[1])
        end
      end

      def schedule_auto_apply(suggestion, config)
        delay = config.auto_apply_delays[suggestion.suggestion_type] ||
                config.auto_apply_delays[suggestion.suggestion_type.to_sym] ||
                config.auto_apply_delay
        scope = { tenant_key: suggestion.tenant_key, account_id: suggestion.account_id }
        scheduler.arity == 2 ? scheduler.call(delay, suggestion.id) : scheduler.call(delay, suggestion.id, scope)
      # NotImplementedError descends from ScriptError, not StandardError, so a
      # bare `rescue` would sail right past it — which is exactly how the
      # inline adapter took down suggest!.
      rescue StandardError, NotImplementedError => e
        # Some queue adapters (ActiveJob's :inline, :async) cannot schedule a
        # job in the future. Losing the auto-apply timer is acceptable; losing
        # the suggestion is not.
        Telemetry.emit("hitl.auto_apply_unavailable",
                       dims: { error_class: e.class.name, type: suggestion.suggestion_type })
        Agentkit.logger&.warn("[AgentKit::HITL] auto-apply not scheduled: #{e.message}")
      end

      # Scheduling port. In Rails the engine swaps this for an ActiveJob
      # `set(wait:).perform_later`; in the core it is a no-op so tests stay
      # deterministic and nothing silently auto-applies.
      def default_scheduler
        lambda do |delay, suggestion_id, _scope = nil|
          Telemetry.emit("hitl.auto_apply_scheduled",
                         dims: { suggestion_id: suggestion_id }, measures: { delay: delay })
        end
      end

      def id_of(obj) = obj.respond_to?(:id) ? obj.id : obj
    end
  end
end
