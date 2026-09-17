# frozen_string_literal: true

module Agentkit
  class WatchtowerJob < ApplicationJob
    queue_as { Agentkit.config.actions.queue }

    def perform
      Agentkit::Watchtower.scan!
    end
  end
end
