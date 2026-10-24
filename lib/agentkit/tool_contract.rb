# frozen_string_literal: true

require "timeout"

module Agentkit
  # Provider-neutral, enforceable contract for every LLM-facing tool. Domain
  # effects remain Capabilities: a ToolContract marked non-read-only refuses
  # direct execution and must be routed through Actions/Policy/HITL.
  class ToolContract
    RISKS = %i[read reversible sensitive irreversible privileged].freeze
    EFFECTS = %i[read_only internal external].freeze

    Execution = Struct.new(
      :result, :evidence, :attempts, :duration_ms, :contract_digest,
      keyword_init: true
    ) do
      def to_h
        { result: result, evidence: evidence, attempts: attempts,
          duration_ms: duration_ms, contract_digest: contract_digest }
      end
    end

    attr_reader :name, :description, :params, :input_schema, :output_schema,
                :risk, :effect, :timeout, :retry_policy, :metadata, :callable

    def initialize(name:, description: nil, params: {}, input_schema: nil,
                   output_schema: nil, preconditions: nil, success_evidence: nil,
                   risk: :read, effect: :read_only, timeout: 30, retry: {},
                   callable: nil, metadata: {})
      @name = required_name(name)
      @description = description.to_s
      @params = (params || {}).transform_keys(&:to_sym).freeze
      @input_schema = Schema.normalize(input_schema || schema_from_params(@params)).freeze
      @output_schema = output_schema && Schema.normalize(output_schema).freeze
      @preconditions = preconditions
      @success_evidence = success_evidence
      @risk = risk.to_sym
      @effect = effect.to_sym
      @timeout = Integer(timeout)
      @retry_policy = normalize_retry(binding.local_variable_get(:retry))
      @callable = callable
      @metadata = deep_freeze(stringify(metadata || {}))
      validate!
    end

    def executable? = !callable.nil?
    def read_only? = effect == :read_only

    # Compatibility with RubyLLM and the former Skill::Tool. Callers needing
    # execution evidence use #invoke; provider SDKs receive the plain result.
    def call(**kwargs) = invoke(kwargs).result

    def invoke(inputs = {}, context: nil, **keyword_inputs)
      raise ToolExecutionDenied, "tool #{name} has no executable adapter" unless executable?
      unless read_only?
        raise ToolExecutionDenied,
              "tool #{name} has #{effect} effects and must execute through Capability/Actions"
      end

      ctx = context || Context.resolve
      raw_inputs = inputs.respond_to?(:to_h) ? inputs.to_h : inputs
      raw_inputs = raw_inputs.merge(keyword_inputs) if raw_inputs.is_a?(Hash) && keyword_inputs.any?
      normalized = raw_inputs.is_a?(Hash) ? symbolize(raw_inputs) : raw_inputs
      Schema.validate!(normalized, input_schema, label: "tool #{name} input")
      check_preconditions!(normalized, ctx)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      history = []
      attempt = 0
      begin
        attempt += 1
        result = nil
        Timeout.timeout(timeout) do
          result = Agentkit.with_context(ctx) { call_adapter(normalized) }
        end
        Schema.validate!(unwrap(result), output_schema, label: "tool #{name} output") if output_schema
        evidence = evidence_for(result, normalized, ctx)
        duration = elapsed_ms(started)
        execution = Execution.new(
          result: result, evidence: evidence, attempts: attempt,
          duration_ms: duration, contract_digest: contract_digest
        ).freeze
        Agentkit.with_context(ctx) do
          Telemetry.emit(
            "tool.execute",
            dims: { tool: name, risk: risk, effect: effect, status: :ok },
            measures: { attempts: attempt, duration_ms: duration }
          )
        end
        execution
      rescue StandardError => e
        decision = Agentkit.with_context(ctx) do
          recovery_policy.decide(e, attempt: attempt, history: history)
        end
        history << decision.failure.fingerprint
        if attempt < retry_policy.fetch(:attempts) && retryable_category?(decision.failure.category) && decision.retry?
          sleep(decision.delay) if decision.delay.positive?
          retry
        end
        Agentkit.with_context(ctx) do
          Telemetry.emit(
            "tool.execute",
            dims: { tool: name, risk: risk, effect: effect, status: :error,
                    category: decision.failure.category, recovery: decision.action },
            measures: { attempts: attempt, duration_ms: elapsed_ms(started) }
          )
        end
        raise
      end
    end

    def to_json_schema
      {
        name: name.to_s,
        description: description,
        parameters: symbolize_schema(input_schema)
      }
    end

    def to_h
      {
        name: name, description: description, input_schema: input_schema,
        output_schema: output_schema, risk: risk, effect: effect, timeout: timeout,
        retry: retry_policy.reject { |key, _| key == :recovery_policy },
        executable: executable?, metadata: metadata
      }.compact
    end

    def contract_digest
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(to_h.reject { |key, _| key == :executable })))}"
    end

    private

    def validate!
      raise ConfigurationError, "tool risk must be one of #{RISKS.inspect}" unless RISKS.include?(risk)
      raise ConfigurationError, "tool effect must be one of #{EFFECTS.inspect}" unless EFFECTS.include?(effect)
      raise ConfigurationError, "tool timeout must be positive" unless timeout.positive?
      unless input_schema["type"] == "object"
        raise ConfigurationError, "tool input_schema must describe an object"
      end
      unless @preconditions.nil? || @preconditions.respond_to?(:call)
        raise ConfigurationError, "tool preconditions must be callable"
      end
      unless @success_evidence.nil? || @success_evidence.respond_to?(:call)
        raise ConfigurationError, "tool success_evidence must be callable"
      end
      if !read_only? && executable?
        Agentkit.logger&.warn(
          "[AgentKit::ToolContract] #{name} is executable but #{effect}; direct calls will be denied"
        )
      end
      true
    end

    def required_name(value)
      text = value.to_s.strip
      raise ArgumentError, "tool name is required" if text.empty?

      text.to_sym
    end

    def schema_from_params(values)
      properties = values.each_with_object({}) do |(key, type), result|
        result[key.to_s] = { "type" => json_type(type) }
      end
      { "type" => "object", "properties" => properties,
        "required" => values.keys.map(&:to_s), "additionalProperties" => false }
    end

    def json_type(type)
      { hash: "object", object: "object", float: "number", number: "number",
        integer: "integer", array: "array", boolean: "boolean", string: "string" }
        .fetch(type.to_sym, type.to_s)
    end

    def normalize_retry(value)
      data = (value || {}).transform_keys(&:to_sym)
      attempts = Integer(data.fetch(:attempts, 1))
      raise ArgumentError, "tool retry attempts must be positive" unless attempts.positive?

      categories = Array(data.fetch(:on, %i[timeout rate_limited transient])).map(&:to_sym)
      unknown = categories - RecoveryPolicy::CATEGORIES
      raise ArgumentError, "unknown retry categories: #{unknown.join(', ')}" if unknown.any?

      policy = data[:recovery_policy] || RecoveryPolicy.new
      raise ArgumentError, "recovery_policy must respond to #decide" unless policy.respond_to?(:decide)
      { attempts: attempts, on: categories.freeze, recovery_policy: policy }.freeze
    end

    def recovery_policy = retry_policy.fetch(:recovery_policy)
    def retryable_category?(category) = retry_policy.fetch(:on).include?(category.to_sym)

    def check_preconditions!(inputs, context)
      return true unless @preconditions

      valid = case @preconditions.arity
              when 0 then @preconditions.call
              when 1 then @preconditions.call(inputs)
              else @preconditions.call(inputs, context)
              end
      raise ToolPreconditionFailed, "tool #{name} preconditions did not hold" unless valid

      true
    rescue ToolPreconditionFailed
      raise
    rescue StandardError => e
      raise ToolPreconditionFailed, "tool #{name} precondition failed: #{e.class}"
    end

    def call_adapter(inputs)
      parameters = callable.respond_to?(:parameters) ? callable.parameters : callable.method(:call).parameters
      keywords = parameters.any? { |kind, _| %i[key keyreq keyrest].include?(kind) }
      positional = parameters.any? { |kind, _| %i[req opt rest].include?(kind) }
      keywords || !positional ? callable.call(**inputs) : callable.call(inputs)
    end

    def evidence_for(result, inputs, context)
      supplied = if @success_evidence
                   case @success_evidence.arity
                   when 0 then @success_evidence.call
                   when 1 then @success_evidence.call(result)
                   when 2 then @success_evidence.call(result, inputs)
                   else @success_evidence.call(result, inputs, context)
                   end
                 else
                   true
                 end
      raise ToolEvidenceMissing, "tool #{name} returned no success evidence" if supplied.nil? || supplied == false

      details = supplied.is_a?(Hash) ? stringify(supplied) : {}
      details.merge(
        "source" => details["source"] || "tool:#{name}",
        "result_digest" => digest(unwrap(result)),
        "verified" => true
      ).freeze
    end

    def unwrap(result) = result.respond_to?(:value) ? result.value : result
    def elapsed_ms(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    def digest(value) = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"

    def canonical(value)
      case value
      when Hash then value.map { |key, item| [key.to_s, canonical(item)] }.sort.to_h
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), out| out[key.to_s] = stringify(item) }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end

    def symbolize(value)
      value.to_h.each_with_object({}) { |(key, item), out| out[key.to_sym] = item }
    end

    def symbolize_schema(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), out| out[key.to_sym] = symbolize_schema(item) }
      when Array then value.map { |item| symbolize_schema(item) }
      else value
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, item| key.freeze; deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      else value.freeze
      end
      value.freeze
    end
  end
end
