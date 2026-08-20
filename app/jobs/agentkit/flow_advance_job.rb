# frozen_string_literal: true

module Agentkit
  # Drives one run forward until it completes or suspends.
  #
  # Enqueued on start, when a fan-out barrier releases, and when a human gate
  # resolves. Re-entrant by construction: the executor re-walks the graph and
  # replays completed steps, so a duplicate delivery is a no-op.
  class FlowAdvanceJob < ApplicationJob
    queue_as :agentkit_flows

    # A run that cannot be advanced now is not a failure to retry forever.
    discard_on ActiveRecord::RecordNotFound

    def perform(run_uuid, scope = nil)
      Agentkit::Flow::Worker.advance(run_uuid, scope)
    end
  end

  # Kept so existing enqueued jobs (and v0.2.0 code) keep working.
  FlowRunJob = FlowAdvanceJob
end
