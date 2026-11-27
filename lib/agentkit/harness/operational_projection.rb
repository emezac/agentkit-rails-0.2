# frozen_string_literal: true

module Agentkit
  module Harness
    # Read-only view over independently authorized, scoped kernel services.
    # A host may render this in a dashboard but must own UI authentication.
    class OperationalProjection
      K = Knowledge
      B = K::Boundary
      TERMINAL_OK = %w[verified no_work].freeze
      NEEDS_ATTENTION = %w[stalled budget_exhausted verification_unavailable policy_violation needs_approval].freeze

      def initialize(runs:, budgets:, escalations:, authorize:, clock: -> { Time.now.utc })
        unless runs.is_a?(UnattendedRun) && budgets.is_a?(Agentkit::SharedBudget) &&
            escalations.is_a?(Operations::Escalations) && authorize.respond_to?(:call) && clock.respond_to?(:call)
          raise K::InvalidContract, "trusted read ports and authorizer required"
        end
        @runs, @budgets, @escalations, @authorize, @clock = runs, budgets, escalations, authorize, clock
      end

      # The host binds budget_id to the run in its own authorized registry. The
      # kernel additionally calls each source's own read policy for this context.
      def fetch(run_id:, budget_id:, context:)
        identity = B.identity(context)
        ids = { "run_id" => identifier(run_id), "budget_id" => identifier(budget_id) }
        guard!(ids, context)
        run = @runs.fetch(id: ids.fetch("run_id"), context: context)
        return nil unless run

        contract = @runs.contract(id: ids.fetch("run_id"), context: context)
        raise K::IntegrityError, "run contract changed during read" unless K.digest(contract) == run.fetch("contract_digest")
        budget = @budgets.fetch(id: ids.fetch("budget_id"), context: context)
        escalation = @escalations.fetch(id: "unattended:#{ids.fetch('run_id')}", context: context)
        if escalation && escalation.fetch("incident_id") != ids.fetch("run_id")
          raise K::IntegrityError, "escalation belongs to another run"
        end
        guard!(ids, context)
        root = budget.fetch("usage").fetch("[]")
        root_limits = budget.fetch("contract").fetch("nodes").find { |node| node.fetch("path").empty? }
        raise K::IntegrityError, "budget root missing" unless root_limits
        limits = root_limits.fetch("limits")
        remaining = %w[cost_microusd tokens concurrency].to_h do |resource|
          [resource, [limits.fetch(resource) - root.fetch(resource), 0].max]
        end
        status = run.fetch("status")
        blockers = []
        blockers << "run:#{status}" if NEEDS_ATTENTION.include?(status)
        blockers << "usage:unknown" unless run.fetch("usage_complete")
        blockers << "budget:expired" if Time.iso8601(budget.fetch("contract").fetch("expires_at")) <= @clock.call.utc
        blockers << "budget:over_limit" if %w[cost_microusd tokens concurrency].any? { |resource| root.fetch(resource) > limits.fetch(resource) }
        blockers << "escalation:exhausted" if escalation && escalation.fetch("status") == "exhausted"
        blockers << "escalation:unacknowledged" if escalation && escalation.fetch("status") == "open"
        B.data(
          schema: "agentkit.operational_projection.v1", run_id: ids.fetch("run_id"),
          tenant: identity.fetch("tenant"), account: identity.fetch("account"),
          observed_at: @clock.call.utc.iso8601(6), point_in_time: false,
          status: status, reason: run["reason"],
          goal: { id: contract.fetch("goal").fetch("id"), digest: contract.fetch("goal_digest"),
                  required_gates: contract.fetch("gates").map { |gate| gate.fetch("id") } },
          evidence: { contract_digest: run.fetch("contract_digest"),
                      commit_sha: run.fetch("artifact").fetch("commit_sha"),
                      artifact_digest: run.fetch("artifact").fetch("digest"),
                      completed_calls: run.fetch("completed_calls"), usage_complete: run.fetch("usage_complete") },
          budget: { id: ids.fetch("budget_id"), usage: root, limits: limits, remaining: remaining },
          escalation: escalation && { id: escalation.fetch("id"), status: escalation.fetch("status"),
            target_index: escalation.fetch("target_index"), attempts: escalation.fetch("attempts"),
            ack_due_at: escalation.fetch("ack_due_at") },
          blockers: blockers, requires_operator: blockers.any?,
          outcome: TERMINAL_OK.include?(status) ? status : nil, authorizes: false
        )
      end

      private

      def identifier(value)
        raise K::InvalidContract, "bounded identifier required" unless value.is_a?(String) && value.bytesize.between?(1, 128)
        value
      end

      def guard!(ids, context)
        raise K::AccessDenied, "operational view denied" unless @authorize.call("read", B.data(ids), context) == true
      end
    end
  end
end
