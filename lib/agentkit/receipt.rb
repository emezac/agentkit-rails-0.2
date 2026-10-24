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

    # Portable change receipt for long-running agent work. Raw output and
    # evidence bodies are intentionally excluded: references, digests and
    # verdicts are enough to audit the completion claim.
    def harness(progress, approvals: [], risks: [])
      unless progress.is_a?(Harness::Progress)
        raise ArgumentError, "progress must be an Agentkit::Harness::Progress"
      end

      evaluation = progress.evaluate!
      recorded_approvals = progress.approvals.values.map do |item|
        item.transform_keys(&:to_sym)
      end
      approval_entries = recorded_approvals + normalize_approvals(approvals)
      approved_names = recorded_approvals.select { |item| item[:status] == "approved" }
                                       .map { |item| item[:name] }
      pending = progress.goal.required_approvals.reject do |requirement|
        approved_names.any? do |name|
          name == requirement ||
            (requirement.end_with?("*") && name.start_with?(requirement.delete_suffix("*")))
        end
      end
      evidence = progress.evidence.values.map do |item|
        {
          criterion_id: item.criterion_id, verdict: item.verdict,
          source: item.source, summary: item.summary, digest: item.digest,
          checked_at: item.checked_at.iso8601(6)
        }.compact
      end
      value = {
        schema: "agentkit.harness.v1",
        kind: "harness",
        goal_id: progress.goal.id,
        goal_digest: progress.goal.digest,
        objective: progress.goal.objective,
        status: progress.status,
        complete: evaluation.complete?,
        steps: { used: progress.step_count, limit: progress.goal.max_steps },
        scope: progress.goal.scope,
        protected_resources: progress.goal.protected_resources,
        outputs: progress.outputs.map do |name, output|
          { name: name, reference: output["reference"], digest: output["digest"] }
        end,
        evidence: evidence,
        verified: evidence.select { |item| item[:verdict] == "verified" }.map { |item| item[:criterion_id] },
        failed: evidence.select { |item| item[:verdict] == "failed" }.map { |item| item[:criterion_id] },
        unresolved: evidence.select { |item| item[:verdict] == "unresolved" }.map { |item| item[:criterion_id] },
        missing: evaluation.missing_criteria + evaluation.missing_constraints,
        missing_outputs: evaluation.missing_outputs,
        missing_approvals: evaluation.missing_approvals,
        risks: Array(risks).map { |risk| sanitize_receipt_item(risk) },
        approvals: {
          required: progress.goal.required_approvals,
          provided: approval_entries,
          pending: pending
        },
        decisions: progress.decisions,
        lessons: progress.lessons,
        open_issues: progress.open_issues,
        generated_at: Time.now.utc.iso8601(6)
      }
      value[:receipt_digest] = Harness.digest(value)
      Harness.deep_freeze(value)
    end

    def index(scope: nil)
      Actions.all(scope: scope).map do |proposal|
        { schema: "agentkit.index.v1", id: proposal.public_id, kind: "action", status: proposal.status,
          digest: proposal.arguments_digest, created_at: proposal.created_at }
      end
    end

    def normalize_approvals(items)
      Array(items).map do |item|
        if item.respond_to?(:to_h)
          data = item.to_h.transform_keys(&:to_sym)
          name = data[:name] || data[:type] || data[:approval]
          {
            name: name.to_s,
            status: (data[:status] || "approved").to_s,
            actor: data[:actor]&.to_s,
            evidence_ref: data[:evidence_ref]&.to_s,
            evidence_digest: data[:evidence_digest]&.then { |value| Harness.valid_digest!(value) }
          }.compact
        else
          { name: item.to_s, status: "approved" }
        end
      end
    end
    private_class_method :normalize_approvals

    def sanitize_receipt_item(item)
      return item.to_s unless item.respond_to?(:to_h)

      item.to_h.each_with_object({}) do |(key, value), out|
        out[key.to_sym] = value.is_a?(Numeric) || value == true || value == false ? value : value.to_s
      end
    end
    private_class_method :sanitize_receipt_item
  end


  module Harness
    module Receipt
      module_function

      def build(progress, approvals: [], risks: [])
        Agentkit::Receipt.harness(progress, approvals: approvals, risks: risks)
      end
    end
  end
end
