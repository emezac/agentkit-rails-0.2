# frozen_string_literal: true

module Agentkit
  # Base for every error raised by the kernel. Domain code can rescue this
  # single class to catch anything AgentKit throws.
  class Error < StandardError; end

  # ─── Configuration ─────────────────────────────────────────────────────────
  class ConfigurationError < Error; end

  # ─── LLM ───────────────────────────────────────────────────────────────────
  class LLMError < Error
    attr_reader :provider, :model

    def initialize(message = nil, provider: nil, model: nil)
      @provider = provider
      @model    = model
      super(message)
    end
  end

  # Retryable: timeouts, rate limits, 5xx. The LLM layer backs off on these.
  class TransientError < LLMError; end
  # Not retryable: bad request, auth, unknown model.
  class PermanentError < LLMError; end
  # The provider answered but the payload did not satisfy the requested schema
  # after the configured number of re-asks.
  class SchemaViolation < LLMError
    attr_reader :raw, :violations

    def initialize(message = nil, raw: nil, violations: [])
      @raw        = raw
      @violations = violations
      super(message)
    end
  end
  # Circuit breaker is open for a provider.
  class CircuitOpen < LLMError; end

  # ─── Budget ────────────────────────────────────────────────────────────────
  class BudgetExceeded < Error
    attr_reader :resource, :limit, :used

    def initialize(message = nil, resource: nil, limit: nil, used: nil)
      @resource = resource
      @limit    = limit
      @used     = used
      super(message || "Budget exceeded for #{resource} (#{used}/#{limit})")
    end
  end

  # ─── Flow ──────────────────────────────────────────────────────────────────
  class FlowError < Error; end
  # Raised at class-definition time by the static validator — a malformed flow
  # fails on boot, never mid-run.
  class FlowDefinitionError < FlowError; end
  class StepFailed < FlowError
    attr_reader :step, :cause_error

    def initialize(message = nil, step: nil, cause_error: nil)
      @step        = step
      @cause_error = cause_error
      super(message)
    end
  end
  class RunCancelled < FlowError; end
  class RunTimedOut  < FlowError; end
  # Raised by the sync executor when it reaches a human_gate and no auto-decision
  # policy applies. The async executor suspends instead of raising.
  class PendingHumanApproval < FlowError
    attr_reader :run, :step_name

    def initialize(message = nil, run: nil, step_name: nil)
      @run       = run
      @step_name = step_name
      super(message || "Run suspended at human gate: #{step_name}")
    end
  end

  # ─── Memory ────────────────────────────────────────────────────────────────
  class MemoryError < Error; end
  class EmbeddingUnavailable < MemoryError; end
  # Attempt to read imagined scenarios as if they were verified facts.
  class OntologicalViolation < MemoryError; end

  # ─── HITL ──────────────────────────────────────────────────────────────────
  class HITLError < Error; end
  class UnknownRejectionCode < HITLError; end
  class SuggestionNotFound < HITLError; end
  class DecisionConflict < HITLError; end
  class IdempotencyConflict < HITLError; end
  class AuditPersistenceError < Error; end

  # ─── Capabilities / proposals ──────────────────────────────────────────────
  class CapabilityError < Error; end
  class PreconditionFailed < CapabilityError; end
end
