# frozen_string_literal: true

module Agentkit
  module MCP
    # Explicit MCP allow-list. Registering is separate from defining a
    # capability, so adding domain code can never silently expand the surface.
    class Registry
      Tool = Struct.new(:name, :capability, :mode, keyword_init: true) do
        def input_schema = capability.input_schema
        def output_schema = capability.output_schema
      end

      attr_reader :tools

      def initialize
        @tools = {}
      end

      def expose(capability, as: nil, mode: nil)
        cap = capability.is_a?(Capability) ? capability : Capability[capability]
        raise ConfigurationError, "unknown capability: #{capability}" unless cap
        raise ConfigurationError, "#{cap.name} is not explicitly exposed to MCP" unless cap.exposed?(:mcp)

        selected_mode = (mode || cap.exposure_mode(:mcp)).to_sym
        if selected_mode == :execute && cap.risk == :irreversible
          raise ConfigurationError, "irreversible capability #{cap.name} may only be proposed over MCP"
        end
        name = (as || "agentkit.#{cap.name}").to_s
        raise ConfigurationError, "duplicate MCP tool #{name}" if @tools.key?(name)

        @tools[name] = Tool.new(name: name, capability: cap, mode: selected_mode)
      end

      def list
        @tools.values.map do |tool|
          { name: tool.name, description: tool.capability.description,
            inputSchema: tool.input_schema, outputSchema: tool.output_schema,
            annotations: { effect: tool.capability.effect.to_s,
                           risk: tool.capability.risk.to_s,
                           permission: tool.capability.required_permission,
                           mode: tool.mode.to_s }.compact }
        end
      end

      def call(name, arguments:, principal:, idempotency_key: nil, context: nil)
        tool = @tools[name.to_s]
        raise CapabilityError, "MCP tool is not exposed: #{name}" unless tool
        raise PolicyDenied, "authenticated MCP principal is required" unless principal

        Actions.invoke(capability: tool.capability, arguments: arguments,
                       principal: principal, mode: tool.mode,
                       idempotency_key: idempotency_key, adapter: :mcp,
                       context: context)
      end
    end
  end
end
