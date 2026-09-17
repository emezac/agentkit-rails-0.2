# frozen_string_literal: true

module Agentkit
  class Capability
    remove_const(:RISKS)
    RISKS = %i[read reversible sensitive irreversible privileged].freeze
    RISK_ALIASES = { costly: :sensitive }.freeze
    EFFECTS = %i[read_only internal external].freeze
    IDEMPOTENCY = %i[none optional required].freeze
    RECONCILIATION = %i[none optional required].freeze

    alias_method :initialize_v1, :initialize
    alias_method :validate_v1!, :validate!
    alias_method :to_h_v1, :to_h

    def initialize(name)
      initialize_v1(name)
      @input_schema = nil
      @output_schema = nil
      @effect = :internal
      @required_permission = nil
      @idempotency = :optional
      @reconciliation = :none
      @reconciler = nil
      @executor = nil
      @timeout = 30
      @max_input_bytes = 64 * 1024
      @contract_version = 1
      @exposures = {}
    end

    def risk(value = nil)
      return @risk if value.nil?

      candidate = value.to_sym
      if RISK_ALIASES.key?(candidate)
        Agentkit.logger&.warn("[AgentKit::Capability] risk :#{candidate} is deprecated; use :#{RISK_ALIASES[candidate]}")
        candidate = RISK_ALIASES.fetch(candidate)
      end
      raise ConfigurationError, "risk must be one of #{RISKS.inspect}" unless RISKS.include?(candidate)

      @risk = candidate
    end

    def input_schema(value = nil) = value.nil? ? effective_input_schema : (@input_schema = value)
    def output_schema(value = nil) = value.nil? ? @output_schema : (@output_schema = value)

    def effect(value = nil)
      return @effect if value.nil?
      raise ConfigurationError, "effect must be one of #{EFFECTS.inspect}" unless EFFECTS.include?(value.to_sym)

      @effect = value.to_sym
    end

    def required_permission(value = nil) = value.nil? ? @required_permission : (@required_permission = value.to_s)

    def idempotency(value = nil)
      return @idempotency if value.nil?
      raise ConfigurationError, "idempotency must be one of #{IDEMPOTENCY.inspect}" unless IDEMPOTENCY.include?(value.to_sym)

      @idempotency = value.to_sym
    end

    def reconciliation(value = nil)
      return @reconciliation if value.nil?
      unless RECONCILIATION.include?(value.to_sym)
        raise ConfigurationError, "reconciliation must be one of #{RECONCILIATION.inspect}"
      end

      @reconciliation = value.to_sym
    end

    def reconciler(value = nil, &block) = value.nil? && !block ? @reconciler : (@reconciler = value || block)
    def executor(value = nil, &block) = value.nil? && !block ? @executor : (@executor = value || block)
    def timeout(value = nil) = value.nil? ? @timeout : (@timeout = Integer(value))
    def max_input_bytes(value = nil) = value.nil? ? @max_input_bytes : (@max_input_bytes = Integer(value))
    def contract_version(value = nil) = value.nil? ? @contract_version : (@contract_version = Integer(value))

    def expose(adapter, mode: :execute)
      raise ConfigurationError, "exposure mode must be :execute or :propose" unless %i[execute propose].include?(mode.to_sym)

      @exposures[adapter.to_sym] = mode.to_sym
    end

    def exposed?(adapter) = @exposures.key?(adapter.to_sym)
    def exposure_mode(adapter) = @exposures[adapter.to_sym]
    def exposures = @exposures.dup
    def external? = @effect == :external
    def legacy_contract? = @input_schema.nil?

    def inputs(value = nil)
      return @inputs if value.nil?

      Agentkit.logger&.warn("[AgentKit::Capability] `inputs` is deprecated; use closed `input_schema`")
      @inputs = value
    end

    def execute(inputs = {}, context: nil, idempotency_key: nil, **keyword_inputs)
      inputs = inputs.merge(keyword_inputs) if inputs.is_a?(Hash) && keyword_inputs.any?
      ctx = context || Context.resolve
      if JSON.generate(inputs).bytesize > max_input_bytes
        raise SchemaValidationError, "capability input exceeds #{max_input_bytes} bytes"
      end
      Schema.validate!(inputs, effective_input_schema, label: "input") unless legacy_contract?
      Telemetry.emit("capability.execute", dims: { capability: name, risk: @risk, effect: @effect })

      result = if @executor
                 call_v2_callable(@executor, inputs, ctx, idempotency_key)
               elsif @flow
                 @flow.call(context: ctx, **inputs)
               elsif @agent
                 @agent.call(inputs, context: ctx)
               else
                 raise CapabilityError, "Capability #{name} has neither executor, flow nor agent"
               end
      validate_v2_output!(result)
      result
    end

    def reconcile(inputs, idempotency_key:, context: nil)
      raise ReconciliationRequired, "Capability #{name} has no reconciler" unless @reconciler

      call_v2_callable(@reconciler, inputs, context || Context.resolve, idempotency_key)
    end

    def validate!
      if @flow.nil? && @agent.nil? && @executor.nil?
        raise ConfigurationError, "Capability #{name} needs an executor, flow or agent"
      end
      if external? && idempotency != :required
        raise ConfigurationError, "external capability #{name} must require idempotency"
      end
      if external? && reconciliation != :required
        raise ConfigurationError, "external capability #{name} must require reconciliation"
      end
      if reconciliation == :required && @reconciler.nil?
        raise ConfigurationError, "capability #{name} requires a reconciler"
      end
      true
    end

    def to_h
      to_h_v1.merge(
        input_schema: effective_input_schema, output_schema: @output_schema,
        effect: @effect, required_permission: @required_permission,
        idempotency: @idempotency, reconciliation: @reconciliation,
        timeout: @timeout, max_input_bytes: @max_input_bytes,
        contract_version: @contract_version, exposures: exposures
      )
    end

    private

    def effective_input_schema
      return Schema.normalize(@input_schema) if @input_schema

      properties = @inputs.each_with_object({}) do |(key, type), result|
        result[key.to_s] = { "type" => v2_schema_type(type) }
      end
      { "type" => "object", "properties" => properties,
        "required" => @inputs.keys.map(&:to_s), "additionalProperties" => true }
    end

    def v2_schema_type(type)
      { string: "string", integer: "integer", float: "number", number: "number",
        array: "array", hash: "object", object: "object", boolean: "boolean" }
        .fetch(type.to_sym, "string")
    end

    def call_v2_callable(callable, inputs, context, idempotency_key)
      method = callable.method(:call)
      parameters = method.parameters
      accepts_keyrest = parameters.any? { |kind, _| kind == :keyrest }
      accepted = parameters.filter_map { |kind, key| key if %i[key keyreq].include?(kind) }
      keywords = { context: context, idempotency_key: idempotency_key }
                 .select { |key, _| accepts_keyrest || accepted.include?(key) }
      callable.call(inputs, **keywords)
    end

    def validate_v2_output!(result)
      return result unless @output_schema
      return result if result.respond_to?(:err?) && result.err?

      value = result.respond_to?(:value) ? result.value : result
      Schema.validate!(value, @output_schema, label: "output")
    end
  end
end
