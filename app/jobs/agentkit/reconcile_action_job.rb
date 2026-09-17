# frozen_string_literal: true

module Agentkit
  class ReconcileActionJob < ApplicationJob
    queue_as { Agentkit.config.actions.queue }

    def perform(proposal_id, scope = {})
      Agentkit::Actions.reconcile!(proposal_id, scope: scope.symbolize_keys)
    end
  end
end
