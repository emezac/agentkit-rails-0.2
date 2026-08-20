# frozen_string_literal: true

module Agentkit
  # Scheduled once per join at fan-out time — not a poller. If the barrier is
  # still open when it fires, the node's `on_timeout` policy applies:
  # `:continue_with_partial` cancels the stragglers and moves on, `:fail` stops
  # the run.
  class FlowJoinTimeoutJob < ApplicationJob
    queue_as :agentkit_flows

    def perform(run_uuid, step_id, policy = "fail", scope = nil)
      Agentkit::Flow::Worker.join_timeout(run_uuid, step_id, policy, scope)
    end
  end
end
