# frozen_string_literal: true

module Agentkit
  class ExecuteSuggestionJob < ApplicationJob
    queue_as :agentkit_hitl

    def perform(suggestion_id, scope = {})
      resolved_scope = scope.symbolize_keys
      suggestion = Agentkit::HITL.fetch!(suggestion_id, scope: resolved_scope)
      Agentkit::A2A::Server.install_hitl_handler!(suggestion.suggestion_type)

      context = Agentkit::Context.new(tenant_key: resolved_scope[:tenant_key],
                                      principal: "system:hitl_executor")
      Agentkit.with_context(context) do
        Agentkit::HITL.execute!(suggestion_id, scope: resolved_scope)
      end
    end
  end
end
