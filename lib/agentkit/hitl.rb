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
      :operation_namespace, :arguments_digest, :lock_version,
      :execution_error_code, :execution_started_at, :execution_finished_at,
      keyword_init: true
    ) do
      def pending?  = status.to_s == "pending"
      def resolved? = %w[approved executing executed execution_failed execution_unknown
                         accepted rejected auto_applied expired].include?(status.to_s)
      def accepted? = %w[approved executing executed execution_failed execution_unknown
                         accepted auto_applied].include?(status.to_s)
      def approved? = accepted?
      def execution_terminal? = %w[executed execution_failed execution_unknown].include?(status.to_s)
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

      def executor
        @executor ||= default_executor
      end

      attr_writer :executor

      def reset!
        @ledger    = Ledger.new
        @store     = Stores::InMemory.new
        @observers = []
        @handlers  = nil
        @handler_keys = nil
        @executor  = nil
        @seq       = 0
        @auto_approve = {}
        @gate_listeners = []
        self
      end

      # ─── Registration ────────────────────────────────────────────────────────

      # What should happen when a suggestion of this type is accepted.
      #
      #   Agentkit::HITL.on("council_recommendation") { |s| ApplyDecision.call(s) }
      def on(type, key: nil, &block)
        if key
          previous = handler_keys[[type.to_s, key.to_s]]
          handlers[type.to_s].delete(previous) if previous
          handler_keys[[type.to_s, key.to_s]] = block
        end
        handlers[type.to_s] << block
        block
      end

      def handler_keys = @handler_keys ||= {}

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
                   experiment_id: nil, experiment_arm: nil, metadata: {},
                   operation_namespace: nil)
        ctx    = context || Context.resolve
        config = ctx.config.hitl
        assignment = if experiment_id
                       { experiment_id: experiment_id, experiment_arm: experiment_arm }
                     elsif prompt_id && prompt_version
                       Prompt.experiment_assignment(prompt_id, version: prompt_version, ctx: ctx)
                     else
                       {}
                     end

        namespace = operation_namespace || "hitl.suggest:#{type}"
        digest = canonical_digest(
          type: type.to_s, title: title, description: description, priority: priority.to_s,
          source_agent: source_agent, payload: payload || {}, gate_key: gate_key,
          prompt_id: prompt_id, prompt_version: prompt_version
        )

        suggestion = Suggestion.new(
          suggestion_type: type.to_s, title: title, description: description,
          priority: priority.to_s, source_agent: source_agent, payload: payload || {},
          suggestable: suggestable, status: config.level == :silent ? "silenced" : "pending",
          user_id: id_of(ctx.user), account_id: id_of(ctx.account), tenant_key: ctx.tenant_key || "__global__",
          idempotency_key: idempotency_key, prompt_id: prompt_id, prompt_version: prompt_version,
          model: model, run_id: ctx.run_id, gate_key: gate_key, created_at: Time.now,
          experiment_id: assignment[:experiment_id], experiment_arm: assignment[:experiment_arm],
          metadata: metadata || {}, operation_namespace: namespace,
          arguments_digest: digest
        )
        # The store assigns the id — the database in production, the sequence
        # in memory. Pre-assigning here would collide with real primary keys.
        suggestion, created = if store.respond_to?(:insert_idempotent)
                                store.insert_idempotent(suggestion)
                              else
                                [store.insert(suggestion), true]
                              end
        unless created
          Telemetry.emit("hitl.deduped",
                         dims: { type: type.to_s, agent: source_agent,
                                 operation_namespace: namespace })
          return suggestion
        end

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
        suggestion = store.transition(id, from: "pending", to: "approved", scope: scope) do |current|
          validate_approval!(current, actor, final_payload)
          edited = !final_payload.nil? && final_payload != current.payload
          current.resolved_at = Time.now
          current.metadata = (current.metadata || {}).merge(
            "decision_actor" => actor.to_s, "decision_mode" => mode.to_s
          )

          # The ledger write participates in the same transaction/critical
          # section as the state transition. A decision cannot exist without
          # consuming the pending proposal exactly once.
          ledger.record(current, decision: edited ? "edited" : "accepted",
                                  actor: actor, mode: mode, final_payload: final_payload,
                                  required: true)
          current.payload = final_payload if edited
        end

        notify(:resolved, suggestion)
        dispatch_execution(suggestion)
      end

      def reject(id, actor: "human", code: nil, note: nil, mode: "human", scope: nil)
        config = Agentkit.config.hitl
        validate_code!(code, config)
        suggestion = store.transition(id, from: "pending", to: "rejected", scope: scope) do |current|
          current.resolved_at = Time.now
          current.metadata = (current.metadata || {}).merge(
            "decision_actor" => actor.to_s, "decision_mode" => mode.to_s
          )
          ledger.record(current, decision: "rejected", actor: actor, mode: mode,
                                  rejection_code: code, rejection_note: note, required: true)
        end

        notify_gate(suggestion)
        notify(:resolved, suggestion)
        suggestion
      end

      def snooze(id, until_time: nil, actor: "human", scope: nil)
        store.transition(id, from: "pending", to: "snoozed", scope: scope) do |suggestion|
          suggestion.expires_at = until_time || (Time.now + 86_400)
          suggestion.metadata = (suggestion.metadata || {}).merge("snoozed_by" => actor.to_s)
        end
      end

      def expire!(id, actor: "system", scope: nil)
        suggestion = store.transition(id, from: %w[pending snoozed], to: "expired", scope: scope) do |current|
          current.resolved_at = Time.now
          ledger.record(current, decision: "expired", actor: actor, mode: "auto", required: true)
        end
        notify_gate(suggestion)
        suggestion
      end

      # Claims an approved decision exactly once and performs its effects. A
      # redelivered job observes a non-approved state and becomes a no-op.
      def execute!(id, scope: nil)
        suggestion = store.claim_execution(id, scope: scope)
        return fetch!(id, scope: scope) if suggestion.nil?

        run_handlers(suggestion)
        notify_gate(suggestion)
        finished = store.finish_execution(id, status: "executed", scope: scope)
        Telemetry.emit("hitl.execution.completed",
                       dims: { type: finished.suggestion_type }, measures: { count: 1 })
        notify(:executed, finished)
        finished
      rescue StandardError => e
        Telemetry.emit("hitl.handler_failed",
                       dims: { type: suggestion&.suggestion_type, error_class: e.class.name })
        Agentkit.logger&.error(
          "[AgentKit::HITL] execution failed suggestion=#{id} error=#{e.class}"
        )
        if suggestion
          failed = store.finish_execution(id, status: "execution_unknown",
                                              error_code: e.class.name, scope: scope)
          notify(:execution_failed, failed)
          failed
        end
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

      def validate_code!(code, config)
        return unless config.require_rejection_code
        return if code && Array(config.rejection_codes).map(&:to_s).include?(code.to_s)

        raise UnknownRejectionCode,
              "reject requires one of: #{Array(config.rejection_codes).join(', ')} (got #{code.inspect})"
      end

      def run_handlers(suggestion)
        handlers[suggestion.suggestion_type].each { |handler| handler.call(suggestion) }
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

      def default_executor
        lambda do |suggestion_id, scope = nil|
          execute!(suggestion_id, scope: scope)
        end
      end

      def dispatch_execution(suggestion)
        scope = { tenant_key: suggestion.tenant_key, account_id: suggestion.account_id }.compact
        executor.call(suggestion.id, scope)
        fetch!(suggestion.id, scope: scope)
      rescue StandardError => e
        failed = store.transition(suggestion.id, from: "approved", to: "execution_failed",
                                                   scope: scope) do |current|
          current.execution_error_code = e.class.name
          current.execution_finished_at = Time.now
        end
        Telemetry.emit("hitl.execution.dispatch_failed",
                       dims: { type: suggestion.suggestion_type, error_class: e.class.name },
                       measures: { count: 1 })
        notify(:execution_failed, failed)
        failed
      end

      def id_of(obj) = obj.respond_to?(:id) ? obj.id : obj
    end
  end
end
