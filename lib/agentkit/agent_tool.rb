# frozen_string_literal: true

module Agentkit
  # Delegation keeps the user-facing conversation in the parent loop. The child
  # uses the same tenant/principal, a narrowed policy and a budget subtree.
  class AgentTool < ToolContract
    attr_reader :agent_class
    OUTPUT_SCHEMA = {
      type: "object", additionalProperties: false,
      properties: {
        answer: { type: ["string", "null"] }, status: { type: "string" },
        evidence_refs: { type: "array", items: { type: "string" } },
        unresolved: { type: "array", items: { type: "string" } }, usage: { type: "object" }
      },
      required: %w[answer status evidence_refs unresolved usage]
    }.freeze

    def initialize(name:, agent:, description:, system: nil, model: nil, timeout: 120)
      unless agent.is_a?(Class) && agent <= Agentkit::Agent
        raise ConfigurationError, "AgentTool requires an Agent subclass"
      end
      @agent_class = agent
      super(name: name, description: description, params: { prompt: :string }, timeout: timeout,
        output_schema: OUTPUT_SCHEMA,
        metadata: { agent_tool: true }, callable: lambda { |prompt:|
          context = Context.resolve
          state = context.loop_state || {}
          child_state = state.merge(depth: state.fetch(:depth, 0) + 1).freeze
          budget = context.budget
          unless budget.is_a?(ExecutionBudget)
            raise ConfigurationError, "AgentTool requires an execution budget"
          end
          if child_state[:depth] > context.config.agent_loop.max_delegation_depth
            raise AgentLoopLimitExceeded, "delegation depth exceeded"
          end
          child_context = context.derive(budget: budget.child, loop_state: child_state)
          child = agent.new(context: child_context)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = nil
          begin
            result = child.run_loop(prompt, system: system, model: model)
            { "answer" => result.answered? ? result.content : nil,
              "status" => result.stop_reason, "evidence_refs" => result.evidence_refs,
              "unresolved" => result.answered? ? [] : [result.stop_reason],
              "usage" => result.usage.to_h }
          ensure
            metrics = result&.execution_metrics || {}
            usage = result&.usage || Usage.zero
            Telemetry.emit(
              "agent_tool.completed",
              dims: { tool: name.to_s, child_agent: agent.name, status: result&.stop_reason || "error",
                      delegation_depth: child_state[:depth], limit_resource: metrics["limit_resource"] },
              measures: {
                duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round,
                turns: result&.turns || 0, input_tokens: usage.input_tokens,
                output_tokens: usage.output_tokens, cost_usd: usage.cost_usd,
                direct_model_calls: metrics.fetch("direct_model_calls", 0),
                nested_model_calls: metrics.fetch("nested_model_calls", 0),
                direct_input_tokens: metrics.fetch("direct_input_tokens", 0),
                direct_output_tokens: metrics.fetch("direct_output_tokens", 0),
                direct_cost_usd: metrics.fetch("direct_cost_usd", 0),
                subtree_model_calls: metrics.fetch("subtree_model_calls", usage.calls),
                subtree_input_tokens: metrics.fetch("subtree_input_tokens", usage.input_tokens),
                subtree_output_tokens: metrics.fetch("subtree_output_tokens", usage.output_tokens),
                subtree_cost_usd: metrics.fetch("subtree_cost_usd", usage.cost_usd),
                tool_calls: metrics.fetch("tool_calls", 0),
                subagent_calls: metrics.fetch("subagent_calls", 0),
                context_total_bytes: metrics.fetch("context_total_bytes", 0),
                context_peak_bytes: metrics.fetch("context_peak_bytes", 0),
                limit_exhausted: metrics.fetch("limit_exhausted", false)
              }
            )
          end
        })
    end
  end
end
