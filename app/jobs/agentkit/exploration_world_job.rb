# frozen_string_literal: true

module Agentkit
  # Horizontal execution unit for adaptive exploration. Jobs carry only a
  # world id and explicit scope; component code is resolved from versioned
  # registries in each worker process.
  class ExplorationWorldJob < ApplicationJob
    queue_as { Agentkit.config.exploration.queue }

    discard_on ActiveRecord::RecordNotFound

    def perform(world_id, scope = {})
      resolved_scope = Agentkit::Scope.resolve(scope)
      context = Agentkit::Context.new(
        account: resolved_scope.account_id, tenant_key: resolved_scope.tenant_key,
        principal: resolved_scope.principal
      )
      Agentkit.with_context(context) do
        Agentkit::Exploration.work(world: world_id, scope: resolved_scope)
      end
    rescue Agentkit::ExplorationInProgress
      # Duplicate delivery while the original worker still owns the lease.
      nil
    end
  end
end
