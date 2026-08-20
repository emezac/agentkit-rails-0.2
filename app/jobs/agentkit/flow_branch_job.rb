# frozen_string_literal: true

module Agentkit
  # One branch of a fan-out. Everything it needs lives in its own step row, so
  # it runs on any worker without the parent process still being alive.
  #
  # On completion it decrements the barrier atomically; the branch that brings
  # the counter to zero enqueues the next advance. Exactly one does.
  class FlowBranchJob < ApplicationJob
    queue_as :agentkit_flows

    # Retries are handled inside the step (`retry:` on the node). A job-level
    # retry here would risk double-decrementing the barrier, so failures are
    # recorded on the step instead.
    def perform(run_uuid, step_id, scope = nil)
      Agentkit::Flow::Worker.run_branch(run_uuid, step_id, scope)
    end
  end
end
