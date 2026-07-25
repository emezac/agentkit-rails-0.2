# frozen_string_literal: true

module Agentkit
  # Fired when a human gate resolves: the approval continues the process
  # instead of ending it, which v0.1 had no way to express.
  class FlowResumeJob < ApplicationJob
    queue_as :agentkit_flows

    def perform(_flow_name, run_uuid)
      Agentkit::Flow::Worker.advance(run_uuid)
    end
  end
end
