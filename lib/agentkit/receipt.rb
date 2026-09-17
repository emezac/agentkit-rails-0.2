# frozen_string_literal: true

module Agentkit
  # Portable, redacted evidence for an action or run. Receipts intentionally
  # contain digests and contract versions instead of raw arguments.
  module Receipt
    module_function

    def action(id, scope: nil)
      proposal = Actions.fetch!(id, scope: scope)
      {
        schema: "agentkit.action.v1",
        kind: "action",
        id: proposal.public_id,
        tenant_key: proposal.tenant_key,
        action_type: proposal.action_type,
        status: proposal.status,
        arguments_digest: proposal.arguments_digest,
        policy_version: proposal.policy_version,
        contract_version: proposal.contract_version,
        decision: Actions.decisions(proposal.id, scope: scope).map do |decision|
          { value: decision.decision, actor_principal_id: decision.actor_principal_id,
            decided_at: decision.decided_at, reason_code: decision.reason_code,
            approved_arguments_digest: decision.approved_arguments_digest }
        end,
        attempts: Actions.attempts(proposal.id, scope: scope).map do |attempt|
          { number: attempt.attempt_number, status: attempt.status,
            idempotency_key: attempt.idempotency_key,
            started_at: attempt.started_at, finished_at: attempt.finished_at,
            error_code: attempt.error_code, external_result_ref: attempt.external_result_ref }
        end,
        outcomes: Actions.outcomes(proposal.id, scope: scope).map do |outcome|
          { kind: outcome.kind, observed_at: outcome.observed_at,
            evidence_digest: outcome.evidence_digest, source: outcome.source,
            confidence: outcome.confidence }
        end
      }.freeze
    end

    def run(run)
      value = run.respond_to?(:to_h) ? run.to_h : run
      { schema: "agentkit.run.v1", kind: "run", digest: Actions.canonical_digest(value),
        run_id: run.respond_to?(:run_id) ? run.run_id : nil }.compact.freeze
    end

    def index(scope: nil)
      Actions.all(scope: scope).map do |proposal|
        { schema: "agentkit.index.v1", id: proposal.public_id, kind: "action", status: proposal.status,
          digest: proposal.arguments_digest, created_at: proposal.created_at }
      end
    end
  end
end
