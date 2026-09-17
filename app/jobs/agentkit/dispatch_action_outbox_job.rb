# frozen_string_literal: true

module Agentkit
  class DispatchActionOutboxJob < ApplicationJob
    queue_as { Agentkit.config.actions.queue }

    def perform(limit = 100)
      Agentkit::Actions.dispatch_pending!(limit: limit)
    end
  end
end
