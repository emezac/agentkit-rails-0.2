# frozen_string_literal: true

module Agentkit
  class ExecuteActionJob < ApplicationJob
    queue_as { Agentkit.config.actions.queue }

    def perform(proposal_id, scope = {})
      Agentkit::Actions.execute!(proposal_id, scope: scope.symbolize_keys)
    end
  end
end
