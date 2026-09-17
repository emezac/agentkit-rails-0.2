# frozen_string_literal: true

require "timeout"

module Agentkit
  # Governed action lifecycle. Authorization, execution attempts and observed
  # outcomes are distinct durable facts and can be inspected independently.
  module Actions
    Proposal = Struct.new(
      :id, :public_id, :tenant_key, :action_type, :arguments, :arguments_digest,
      :requester_principal_id, :required_permission, :target_type, :target_id,
      :risk, :effect, :policy_version, :contract_version, :status,
      :operation_namespace, :idempotency_key, :source_adapter,
      :canonical_response, :expires_at, :created_at, :updated_at, :lock_version,
      keyword_init: true
    )
    Decision = Struct.new(
      :id, :proposal_id, :tenant_key, :decision, :actor_principal_id,
      :decided_at, :approved_arguments_digest, :policy_version, :reason_code,
      keyword_init: true
    )
    ExecutionAttempt = Struct.new(
      :id, :proposal_id, :tenant_key, :attempt_number, :idempotency_key,
      :status, :started_at, :finished_at, :error_code, :external_result_ref,
      :canonical_response, keyword_init: true
    )
    Outcome = Struct.new(
      :id, :proposal_id, :tenant_key, :kind, :observed_at, :value,
      :evidence_digest, :source, :confidence, keyword_init: true
    )
    Outbox = Struct.new(
      :id, :proposal_id, :tenant_key, :event_type, :status,
      :delivery_attempts, :dispatched_at, :last_error_code, :created_at,
      keyword_init: true
    )

    module StateMachine
      TRANSITIONS = {
        "draft" => %w[open],
        "open" => %w[approved rejected expired cancelled],
        "approved" => %w[executing],
        "executing" => %w[executed execution_failed execution_unknown],
        "execution_unknown" => %w[executed execution_failed executing],
        "execution_failed" => %w[executing]
      }.freeze

      module_function

      def allowed?(from, to) = Array(TRANSITIONS[from.to_s]).include?(to.to_s)

      def validate!(from, to)
        return true if allowed?(from, to)

        raise ActionTransitionConflict, "action cannot transition from #{from} to #{to}"
      end
    end

    class << self
      attr_writer :store, :dispatcher

      def store
        @store ||= build_store
      end

      def dispatcher
        @dispatcher ||= ->(proposal_id, scope) { execute!(proposal_id, scope: scope) }
      end

      def reset!
        @store = nil
        @dispatcher = nil
        self
      end

      def invoke(capability:, arguments:, principal:, mode: :execute,
                 idempotency_key: nil, adapter: :internal, context: nil)
        cap = capability.is_a?(Capability) ? capability : Capability[capability]
        raise CapabilityError, "unknown capability: #{capability}" unless cap

        ctx = context || Context.resolve
        actor = Principal.coerce(principal, tenant_key: ctx.tenant_key, source: adapter)
        policy = Policy.resolve(capability: cap, principal: actor, mode: mode, context: ctx)
        raise PolicyDenied, "policy denied #{cap.name}: #{policy.reason}" if policy.deny?

        if cap.effect == :read_only && policy.permit?
          return { status: "completed", result: cap.execute(arguments, context: ctx) }
        end

        proposal = propose!(capability: cap, arguments: arguments, requester: actor,
                            idempotency_key: idempotency_key, source_adapter: adapter,
                            policy_version: policy.policy_version, context: ctx)
        if policy.permit?
          proposal = authorize_by_policy!(proposal, policy: policy)
          proposal = find(proposal.id, scope: { tenant_key: proposal.tenant_key })
        end
        { status: task_status(proposal), proposal: proposal, task_id: "action:#{proposal.public_id}" }
      end

      def propose!(capability:, arguments:, requester:, idempotency_key: nil,
                   operation_namespace: nil, source_adapter: nil, target: nil,
                   expires_at: nil, policy_version: Policy::VERSION, context: nil)
        cap = capability.is_a?(Capability) ? capability : Capability[capability]
        raise CapabilityError, "unknown capability: #{capability}" unless cap

        ctx = context || Context.resolve
        principal = Principal.coerce(requester, tenant_key: ctx.tenant_key, source: source_adapter)
        raise PolicyDenied, "authenticated requester principal is required" unless principal
        if cap.idempotency == :required && idempotency_key.to_s.empty?
          raise IdempotencyConflict, "capability #{cap.name} requires an idempotency key"
        end
        Schema.validate!(arguments, cap.input_schema, label: "input")
        digest = canonical_digest(arguments)
        proposal = Proposal.new(
          public_id: SecureRandom.hex(16),
          tenant_key: ctx.tenant_key || principal.tenant_key || "__global__",
          action_type: cap.name.to_s, arguments: arguments, arguments_digest: digest,
          requester_principal_id: principal.id, required_permission: cap.required_permission,
          target_type: target&.class&.name, target_id: object_id_of(target),
          risk: cap.risk.to_s, effect: cap.effect.to_s, policy_version: policy_version,
          contract_version: cap.contract_version.to_s, status: "draft",
          operation_namespace: operation_namespace || "action:#{cap.name}",
          idempotency_key: idempotency_key, source_adapter: source_adapter&.to_s,
          expires_at: expires_at, created_at: Time.now, updated_at: Time.now
        )
        proposal, created = store.create_proposal(proposal)
        return proposal unless created

        proposal = store.transition(proposal.id, from: "draft", to: "open")
        Audit.record(event_type: "action.proposed", status: "open",
                     payload: audit_payload(proposal), context: ctx,
                     failure_mode: audit_mode(cap))
        Telemetry.emit("action.proposed", dims: { action: cap.name, risk: cap.risk,
                                                  adapter: source_adapter })
        proposal
      rescue IdempotencyConflict
        Telemetry.emit("idempotency.conflict", dims: { operation: operation_namespace || "action:#{cap&.name}" })
        raise
      end

      def decide!(id, decision:, actor:, reason_code: nil, scope: nil)
        proposal = fetch!(id, scope: scope)
        unless %w[approved rejected].include?(decision.to_s)
          raise ActionTransitionConflict, "decision must be approved or rejected"
        end
        principal = Principal.coerce(actor, tenant_key: proposal.tenant_key)
        raise PolicyDenied, "authenticated decision principal is required" unless principal
        if decision.to_s == "approved" && principal.id == proposal.requester_principal_id
          raise SeparationOfDutiesViolation, "requester cannot approve its own action"
        end
        unless principal.allowed?(proposal.required_permission)
          raise PolicyDenied, "principal lacks #{proposal.required_permission}"
        end

        value = Decision.new(
          proposal_id: proposal.id, tenant_key: proposal.tenant_key,
          decision: decision.to_s, actor_principal_id: principal.id,
          decided_at: Time.now,
          approved_arguments_digest: decision.to_s == "approved" ? proposal.arguments_digest : nil,
          policy_version: proposal.policy_version, reason_code: reason_code&.to_s
        )
        updated, outbox = store.decide(proposal.id, value, create_outbox: decision.to_s == "approved")
        Audit.record(event_type: "action.decided", status: decision.to_s,
                     payload: audit_payload(updated).merge("actor_digest" => canonical_digest(principal.id)),
                     context: action_context(updated, principal),
                     failure_mode: audit_mode(Capability[updated.action_type]))
        if outbox
          dispatch_outbox(outbox)
          updated = find(updated.id, scope: { tenant_key: updated.tenant_key })
        end
        updated
      end

      def cancel!(id, actor:, scope: nil)
        proposal = fetch!(id, scope: scope)
        principal = Principal.coerce(actor, tenant_key: proposal.tenant_key)
        raise PolicyDenied, "authenticated principal is required" unless principal

        updated = store.transition(proposal.id, from: "open", to: "cancelled")
        Audit.record(event_type: "action.cancelled", status: "cancelled",
                     payload: audit_payload(updated),
                     context: action_context(updated, principal),
                     failure_mode: audit_mode(Capability[updated.action_type]))
        updated
      end

      def expire_due!(now: Time.now, scope: nil)
        all(scope: scope).filter_map do |proposal|
          next unless proposal.status == "open" && proposal.expires_at && proposal.expires_at <= now

          store.transition(proposal.id, from: "open", to: "expired")
        rescue ActionTransitionConflict
          nil
        end
      end

      def execute!(id, scope: nil, retry_failed: false, retry_unknown: false)
        proposal, attempt = store.claim_execution(id, scope: scope,
                                                      retry_failed: retry_failed,
                                                      retry_unknown: retry_unknown)
        return fetch!(id, scope: scope) unless proposal

        capability = Capability[proposal.action_type]
        raise CapabilityError, "capability #{proposal.action_type} is no longer registered" unless capability

        ctx = action_context(proposal, Principal.new(id: "system:action_executor",
                                                      tenant_key: proposal.tenant_key,
                                                      permissions: ["*"]))
        Audit.record(event_type: "action.execution.started", status: "executing",
                     payload: audit_payload(proposal).merge("attempt" => attempt.attempt_number),
                     context: ctx, failure_mode: audit_mode(capability))
        result = nil
        Timeout.timeout(capability.timeout) do
          result = capability.execute(symbolize_json(proposal.arguments), context: ctx,
                                      idempotency_key: attempt.idempotency_key)
        end
        if result.respond_to?(:err?) && result.err?
          raise(result.error.is_a?(Exception) ? result.error : CapabilityError.new(result.error.to_s))
        end

        response = canonical_response(result)
        reference = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(response))}"
        Audit.record(event_type: "action.execution.finished", status: "executed",
                     payload: audit_payload(proposal).merge("result_ref" => reference),
                     context: ctx, failure_mode: audit_mode(capability))
        finished = store.finish_execution(proposal.id, attempt.id, status: "executed",
                                           canonical_response: response,
                                           external_result_ref: reference, scope: scope)
        finished
      rescue StandardError => e
        raise unless proposal && attempt

        terminal = capability&.external? ? "execution_unknown" : "execution_failed"
        failed = store.finish_execution(proposal.id, attempt.id, status: terminal,
                                         error_code: e.class.name, scope: scope)
        Telemetry.emit(terminal == "execution_unknown" ? "action.execution.unknown" : "action.execution.failed",
                       dims: { action: proposal.action_type, status: terminal,
                               error_class: e.class.name })
        failed
      end

      def reconcile!(id, scope: nil)
        proposal = fetch!(id, scope: scope)
        raise ReconciliationRequired, "action is not execution_unknown" unless proposal.status == "execution_unknown"

        capability = Capability[proposal.action_type]
        raise ReconciliationRequired, "capability is unavailable" unless capability

        ctx = action_context(proposal, Principal.new(id: "system:reconciler",
                                                      tenant_key: proposal.tenant_key,
                                                      permissions: ["*"]))
        verdict = capability.reconcile(symbolize_json(proposal.arguments),
                                       idempotency_key: stable_execution_key(proposal), context: ctx)
        status, reference = normalize_reconciliation(verdict)
        reconciled = case status
                     when :executed
                       store.reconcile(proposal.id, to: "executed", external_result_ref: reference, scope: scope)
                     when :failed
                       store.reconcile(proposal.id, to: "execution_failed", external_result_ref: reference, scope: scope)
                     when :absent
                       execute!(proposal.id, scope: scope, retry_unknown: true)
                     else
                       raise ReconciliationRequired, "reconciler returned an unknown verdict"
                     end
        Audit.record(event_type: "action.reconciled", status: reconciled.status,
                     payload: audit_payload(reconciled).merge("external_result_ref" => reference),
                     context: ctx, failure_mode: audit_mode(capability))
        Telemetry.emit("action.reconciled", dims: { action: proposal.action_type,
                                                     status: reconciled.status })
        reconciled
      end

      def observe_outcome!(id, kind:, value:, source:, confidence: nil,
                           evidence: nil, observed_at: Time.now, scope: nil)
        proposal = fetch!(id, scope: scope)
        digest = canonical_digest(evidence || value)
        outcome = store.add_outcome(Outcome.new(
          proposal_id: proposal.id, tenant_key: proposal.tenant_key, kind: kind.to_s,
          observed_at: observed_at, value: value, evidence_digest: digest,
          source: source.to_s, confidence: confidence
        ))
        Audit.record(event_type: "action.outcome.observed", status: kind.to_s,
                     payload: audit_payload(proposal).merge("evidence_digest" => digest,
                                                            "source" => source.to_s),
                     context: action_context(proposal, Context.current&.principal))
        outcome
      end

      def find(id, scope: nil) = store.find_proposal(id, scope: scope)
      def fetch!(id, scope: nil) = find(id, scope: scope) || raise(ActionNotFound, "action #{id} not found")
      def decisions(id, scope: nil) = store.decisions(fetch!(id, scope: scope).id)
      def attempts(id, scope: nil) = store.attempts(fetch!(id, scope: scope).id)
      def outcomes(id, scope: nil) = store.outcomes(fetch!(id, scope: scope).id)
      def all(scope: nil) = store.proposals(scope: scope)

      def dispatch_pending!(limit: 100)
        store.pending_outboxes(limit: limit).each { |outbox| dispatch_outbox(outbox) }
      end

      def task_status(proposal)
        case proposal.status
        when "draft", "open" then "pending_approval"
        when "approved" then "approved"
        when "executing" then "working"
        when "executed" then "completed"
        when "execution_failed", "execution_unknown" then "failed"
        else proposal.status
        end
      end

      def canonical_digest(value)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(normalize_json(value)))}"
      end

      private

      def authorize_by_policy!(proposal, policy:)
        decision = Decision.new(
          proposal_id: proposal.id, tenant_key: proposal.tenant_key,
          decision: "approved", actor_principal_id: "policy:#{policy.policy_version}",
          decided_at: Time.now, approved_arguments_digest: proposal.arguments_digest,
          policy_version: policy.policy_version, reason_code: policy.reason.to_s
        )
        updated, outbox = store.decide(proposal.id, decision, create_outbox: true)
        dispatch_outbox(outbox)
        updated
      end

      def dispatch_outbox(outbox)
        scope = { tenant_key: outbox.tenant_key }
        dispatcher.call(outbox.proposal_id, scope)
        store.mark_outbox(outbox.id, status: "dispatched")
      rescue StandardError => e
        store.mark_outbox(outbox.id, status: "pending", error_code: e.class.name)
        Telemetry.emit("action.outbox_failed", dims: { error_class: e.class.name })
        nil
      end

      def build_store
        if Agentkit.config.actions.store.to_sym == :active_record && defined?(Agentkit::ActionProposalRecord)
          Stores::ActiveRecord.new
        else
          Stores::InMemory.new
        end
      end

      def audit_mode(capability)
        capability && (capability.external? || capability.irreversible?) ? :required : nil
      end

      def audit_payload(proposal)
        { "proposal_id" => proposal.public_id, "action_type" => proposal.action_type,
          "arguments_digest" => proposal.arguments_digest, "risk" => proposal.risk,
          "effect" => proposal.effect, "policy_version" => proposal.policy_version }
      end

      def action_context(proposal, principal)
        Context.new(tenant_key: proposal.tenant_key, principal: principal,
                    metadata: { action_proposal_id: proposal.public_id })
      end

      def stable_execution_key(proposal)
        proposal.idempotency_key.presence || "action:#{proposal.public_id}"
      rescue NoMethodError
        proposal.idempotency_key.to_s.empty? ? "action:#{proposal.public_id}" : proposal.idempotency_key
      end

      def canonical_response(result)
        value = result.respond_to?(:value) ? result.value : result
        case value
        when Hash, Array, String, Numeric, TrueClass, FalseClass, NilClass then value
        else value.respond_to?(:id) ? { "type" => value.class.name, "id" => value.id } : value.to_s
        end
      end

      def normalize_reconciliation(value)
        return [value.to_sym, nil] if value.is_a?(String) || value.is_a?(Symbol)
        return [value[:status].to_sym, value[:external_result_ref]] if value.is_a?(Hash)

        [nil, nil]
      end

      def normalize_json(value)
        case value
        when Hash then value.map { |key, item| [key.to_s, normalize_json(item)] }.sort.to_h
        when Array then value.map { |item| normalize_json(item) }
        else value
        end
      end

      def symbolize_json(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_sym] = symbolize_json(item) }
        when Array then value.map { |item| symbolize_json(item) }
        else value
        end
      end

      def object_id_of(object) = object.respond_to?(:id) ? object.id.to_s : nil
    end
  end
end

require_relative "actions/stores"
