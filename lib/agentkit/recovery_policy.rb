# frozen_string_literal: true

module Agentkit
  # One failure vocabulary shared by tools, harnesses and domain adapters.
  # Classification and recovery are deliberately separate: applications may
  # classify with domain knowledge while the policy keeps retries bounded.
  class RecoveryPolicy
    CATEGORIES = %i[
      timeout rate_limited invalid_arguments missing_context failed_check
      permission_denied contradictory_requirements ambiguous_effect
      repeated_unchanged transient permanent unknown
    ].freeze
    ACTIONS = %i[retry repair retrieve request_approval escalate reconcile stop].freeze

    Failure = Struct.new(:category, :error_class, :message, :fingerprint, keyword_init: true) do
      def to_h
        { category: category, error_class: error_class, message: message,
          fingerprint: fingerprint }
      end
    end

    Decision = Struct.new(
      :failure, :action, :attempt, :retry_limit, :delay, :reason,
      keyword_init: true
    ) do
      def retry? = %i[retry repair retrieve].include?(action.to_sym)
      def exhausted? = reason.to_sym == :retry_limit_exhausted

      def to_h
        { failure: failure.to_h, action: action, attempt: attempt,
          retry_limit: retry_limit, delay: delay, reason: reason }
      end
    end

    DEFAULT_RULES = {
      timeout:                    { action: :retry, retry_limit: 2, backoff: 0.25, exhausted: :escalate },
      rate_limited:               { action: :retry, retry_limit: 3, backoff: 0.5, exhausted: :escalate },
      transient:                  { action: :retry, retry_limit: 2, backoff: 0.25, exhausted: :escalate },
      invalid_arguments:          { action: :repair, retry_limit: 1, backoff: 0, exhausted: :stop },
      missing_context:            { action: :retrieve, retry_limit: 1, backoff: 0, exhausted: :escalate },
      failed_check:               { action: :repair, retry_limit: 1, backoff: 0, exhausted: :escalate },
      permission_denied:          { action: :request_approval, retry_limit: 0, backoff: 0, exhausted: :request_approval },
      contradictory_requirements: { action: :escalate, retry_limit: 0, backoff: 0, exhausted: :escalate },
      ambiguous_effect:           { action: :reconcile, retry_limit: 0, backoff: 0, exhausted: :reconcile },
      repeated_unchanged:         { action: :stop, retry_limit: 0, backoff: 0, exhausted: :stop },
      permanent:                  { action: :stop, retry_limit: 0, backoff: 0, exhausted: :stop },
      unknown:                    { action: :escalate, retry_limit: 0, backoff: 0, exhausted: :escalate }
    }.freeze

    attr_reader :rules, :repeated_threshold

    def initialize(rules: {}, repeated_threshold: 2)
      @rules = DEFAULT_RULES.each_with_object({}) do |(category, rule), result|
        override = rules[category] || rules[category.to_s] || {}
        result[category] = normalize_rule(rule.merge(symbolize(override)))
      end.freeze
      @repeated_threshold = Integer(repeated_threshold)
      raise ArgumentError, "repeated_threshold must be positive" unless @repeated_threshold.positive?
    end

    def classify(error, category: nil)
      chosen = category&.to_sym || inferred_category(error)
      raise ArgumentError, "unknown failure category: #{chosen.inspect}" unless CATEGORIES.include?(chosen)

      message = error.respond_to?(:message) ? error.message.to_s : error.to_s
      Failure.new(
        category: chosen, error_class: error.class.name, message: message.slice(0, 500),
        fingerprint: fingerprint(chosen, error.class.name, message)
      ).freeze
    end

    # `history` contains fingerprints from prior failed attempts. An unchanged
    # failure is stopped before another paid repetition.
    def decide(error, attempt:, history: [], category: nil)
      failure = error.is_a?(Failure) ? error : classify(error, category: category)
      previous = Array(history).last(repeated_threshold)
      if previous.size >= repeated_threshold && previous.all? { |item| item.to_s == failure.fingerprint }
        failure = classify(error, category: :repeated_unchanged)
      end

      rule = rules.fetch(failure.category)
      number = Integer(attempt)
      raise ArgumentError, "attempt must be positive" unless number.positive?

      exhausted = number > rule.fetch(:retry_limit)
      action = exhausted && retry_action?(rule.fetch(:action)) ? rule.fetch(:exhausted) : rule.fetch(:action)
      decision = Decision.new(
        failure: failure, action: action, attempt: number,
        retry_limit: rule.fetch(:retry_limit),
        delay: action == :retry ? exponential_delay(rule.fetch(:backoff), number) : 0.0,
        reason: exhausted && retry_action?(rule.fetch(:action)) ? :retry_limit_exhausted : :classified
      ).freeze

      Telemetry.emit(
        "recovery.decision",
        dims: { category: failure.category, action: decision.action, reason: decision.reason },
        measures: { attempt: number, retry_limit: decision.retry_limit, delay_s: decision.delay }
      ) if defined?(Telemetry)
      decision
    end

    private

    def inferred_category(error)
      return :timeout if defined?(Timeout::Error) && error.is_a?(Timeout::Error)
      return :transient if error.is_a?(TransientError)
      return :permanent if error.is_a?(PermanentError)
      return :invalid_arguments if error.is_a?(SchemaValidationError) || error.is_a?(ArgumentError)
      return :permission_denied if error.is_a?(PolicyDenied) || error.is_a?(ToolExecutionDenied)
      return :ambiguous_effect if error.is_a?(ReconciliationRequired)
      return :missing_context if error.is_a?(ContextMapError)
      return :failed_check if error.is_a?(ToolPreconditionFailed) ||
                              error.is_a?(ToolEvidenceMissing) ||
                              error.is_a?(VerificationError)
      return :permanent if error.is_a?(BudgetExceeded)

      message = error.respond_to?(:message) ? error.message.to_s.downcase : error.to_s.downcase
      return :rate_limited if message.match?(/rate.?limit|\b429\b|quota/)
      return :missing_context if message.match?(/missing context|not found|unknown source/)
      return :failed_check if message.match?(/test failed|check failed|verification failed/)
      return :contradictory_requirements if message.match?(/contradict|mutually exclusive/)

      :unknown
    end

    def normalize_rule(rule)
      value = symbolize(rule)
      action = value.fetch(:action).to_sym
      exhausted = value.fetch(:exhausted).to_sym
      raise ArgumentError, "unknown recovery action: #{action.inspect}" unless ACTIONS.include?(action)
      raise ArgumentError, "unknown exhausted action: #{exhausted.inspect}" unless ACTIONS.include?(exhausted)

      retry_limit = Integer(value.fetch(:retry_limit))
      backoff = Float(value.fetch(:backoff))
      raise ArgumentError, "retry_limit cannot be negative" if retry_limit.negative?
      raise ArgumentError, "backoff cannot be negative" if backoff.negative?

      { action: action, exhausted: exhausted, retry_limit: retry_limit, backoff: backoff }.freeze
    end

    def retry_action?(action) = %i[retry repair retrieve].include?(action.to_sym)
    def exponential_delay(base, attempt) = (base.to_f * (2**([attempt - 1, 0].max))).round(3)

    def fingerprint(category, error_class, message)
      normalized = message.to_s.downcase.gsub(/\b\d+\b/, "#").gsub(/\s+/, " ").strip
      "sha256:#{Digest::SHA256.hexdigest([category, error_class, normalized].join('|'))}"
    end

    def symbolize(value)
      value.to_h.each_with_object({}) { |(key, item), out| out[key.to_sym] = item }
    end
  end
end
