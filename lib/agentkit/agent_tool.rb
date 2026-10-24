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
          result = child.run_loop(prompt, system: system, model: model)
          { "answer" => result.answered? ? result.content : nil,
            "status" => result.stop_reason, "evidence_refs" => result.evidence_refs,
            "unresolved" => result.answered? ? [] : [result.stop_reason],
            "usage" => result.usage.to_h }
        })
    end
  end
end
