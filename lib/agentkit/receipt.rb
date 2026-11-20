# frozen_string_literal: true

module Agentkit
  # Portable, redacted evidence for an action or run. Receipts intentionally
  # contain digests and contract versions instead of raw arguments.
  module Receipt
    MAX_EXECUTION_ITEMS = 64
    MAX_EXECUTION_BYTES = 128 * 1024

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

      evaluation = progress.evaluate
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
        status: evaluation.status,
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
      if evaluation.verification_status != "not_required"
        value[:verification] = {
          status: evaluation.verification_status,
          review_digest: progress.verification&.fetch("review_digest"),
          subject_digest: progress.verification&.fetch("subject_digest")
        }.compact
      end
      value[:receipt_digest] = Harness.digest(value)
      Harness.deep_freeze(value)
    end

    # A bounded, redacted account of what the harness used and observed during
    # execution. This is evidence only: it grants no permission and contains no
    # prompts, tool arguments/results, provider responses or context bodies.
    def execution(progress:, policy_version:, outcome: nil, context_sources: [], tools: [],
                  verification: [], artifact: nil, rollback: nil, human_corrections: 0,
                  approvals: [], risks: [], metadata: {})
      corrections = Integer(human_corrections)
      raise ArgumentError, "human_corrections cannot be negative" if corrections.negative?

      runtime = outcome && runtime_receipt(outcome)
      sources = receipt_items(Array(runtime && runtime[:context_sources]) + Array(context_sources),
                              &method(:context_source_receipt))
      contracts = receipt_items(Array(runtime && runtime[:tool_contracts]) + Array(tools),
                                &method(:tool_receipt))
      value = {
        schema: "agentkit.execution_receipt.v1",
        kind: "execution",
        authorizes: false,
        policy_version: required_receipt_text(policy_version, "policy_version"),
        harness: execution_harness_receipt(progress, approvals: approvals, risks: risks),
        runtime: runtime&.except(:context_sources, :tool_contracts),
        context_sources: sources,
        tools: contracts,
        verification: receipt_items(verification, &method(:verification_receipt)),
        artifact: reference_receipt(artifact, "artifact"),
        rollback: reference_receipt(rollback, "rollback"),
        human_corrections: corrections,
        metadata: scalar_metadata(metadata),
        generated_at: Time.now.utc.iso8601(6)
      }.compact
      raise ArgumentError, "execution receipt exceeds #{MAX_EXECUTION_BYTES} bytes" if
        JSON.generate(value).bytesize > MAX_EXECUTION_BYTES

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

    def runtime_receipt(outcome)
      raw = {}
      raw[:stop_reason] = required_receipt_text(outcome.stop_reason, "stop_reason") if outcome.respond_to?(:stop_reason)
      raw[:turns] = Integer(outcome.turns) if outcome.respond_to?(:turns) && !outcome.turns.nil?
      raw[:error_code] = required_receipt_text(outcome.error_code, "error_code") if
        outcome.respond_to?(:error_code) && outcome.error_code
      raw[:verifier_rejections] = Integer(outcome.verifier_rejections) if
        outcome.respond_to?(:verifier_rejections) && !outcome.verifier_rejections.nil?
      if outcome.respond_to?(:model_route) && outcome.model_route
        raw[:model_route] = scalar_fields(outcome.model_route, %w[profile model provider])
      end
      if outcome.respond_to?(:usage) && outcome.usage
        usage = outcome.usage.respond_to?(:to_h) ? outcome.usage.to_h : outcome.usage
        raw[:usage] = scalar_fields(
          usage, %w[input_tokens output_tokens total_tokens cost_usd duration_ms calls cached model]
        )
      end
      raw[:budget] = budget_receipt(outcome.budget) if outcome.respond_to?(:budget) && outcome.budget
      raw[:loaded_skills] = bounded_texts(outcome.loaded_skills) if outcome.respond_to?(:loaded_skills)
      raw[:evidence_refs] = bounded_texts(outcome.evidence_refs) if outcome.respond_to?(:evidence_refs)
      raw[:context_sources] = outcome.context_sources if outcome.respond_to?(:context_sources)
      raw[:tool_contracts] = outcome.tool_contracts if outcome.respond_to?(:tool_contracts)
      Harness.deep_freeze(raw)
    end
    private_class_method :runtime_receipt

    def execution_harness_receipt(progress, approvals:, risks:)
      unless progress.is_a?(Harness::Progress)
        raise ArgumentError, "progress must be an Agentkit::Harness::Progress"
      end

      evaluation = progress.evaluate
      recorded = progress.approvals.values.map { |item| item.transform_keys(&:to_sym) }
      supplied = normalize_approvals(approvals)
      approved = (recorded + supplied).select { |item| item[:status] == "approved" }.map { |item| item[:name] }
      pending = progress.goal.required_approvals.reject do |requirement|
        approved.any? do |name|
          name == requirement || (requirement.end_with?("*") && name.start_with?(requirement.delete_suffix("*")))
        end
      end
      Harness.deep_freeze(
        schema: "agentkit.execution_harness.v1", goal_id: progress.goal.id,
        goal_digest: progress.goal.digest, progress_digest: Harness.digest(progress.to_h),
        status: evaluation.status, complete: evaluation.complete?,
        steps: { used: progress.step_count, limit: progress.goal.max_steps },
        outputs: progress.outputs.map do |name, output|
          { name: name, reference: output["reference"], digest: output["digest"] }
        end,
        evidence: progress.evidence.values.map do |item|
          {
            criterion_id: item.criterion_id, verdict: item.verdict,
            source: item.source, digest: item.digest, checked_at: item.checked_at.iso8601(6)
          }.compact
        end,
        missing: evaluation.missing_criteria + evaluation.missing_constraints,
        missing_outputs: evaluation.missing_outputs, missing_approvals: pending,
        approvals: { required: progress.goal.required_approvals, provided: recorded + supplied, pending: pending },
        risks: Array(risks).first(MAX_EXECUTION_ITEMS).map { |risk| sanitize_receipt_item(risk) }
      )
    end
    private_class_method :execution_harness_receipt

    def budget_receipt(value)
      data = receipt_hash(value)
      result = select_receipt_fields(data, %w[admitted_calls unmeasured_calls])
      result["limits"] = scalar_fields(data["limits"], %w[max_turns max_tokens max_cost_usd]) if data["limits"]
      result["usage"] = scalar_fields(
        data["usage"], %w[input_tokens output_tokens total_tokens cost_usd duration_ms calls cached model]
      ) if data["usage"]
      result["subtree_usage"] = scalar_fields(
        data["subtree_usage"], %w[input_tokens output_tokens total_tokens cost_usd duration_ms calls cached model]
      ) if data["subtree_usage"]
      result["unpriced_models"] = bounded_texts(data["unpriced_models"]) if data["unpriced_models"]
      Harness.deep_freeze(result)
    end
    private_class_method :budget_receipt

    def receipt_items(items)
      Array(items).first(MAX_EXECUTION_ITEMS).filter_map { |item| yield(item) }.freeze
    end
    private_class_method :receipt_items

    def context_source_receipt(item)
      data = receipt_hash(item)
      selected = select_receipt_fields(
        data, %w[source_id name skill kind reference digest observed_at truncated]
      )
      selected["digest"] = Harness.valid_digest!(selected["digest"]) if selected["digest"]
      selected.empty? ? nil : Harness.deep_freeze(selected)
    end
    private_class_method :context_source_receipt

    def tool_receipt(item)
      data = item.is_a?(ToolContract) ? {
        "name" => item.name, "contract_digest" => item.contract_digest,
        "risk" => item.risk, "effect" => item.effect
      } : receipt_hash(item)
      selected = select_receipt_fields(data, %w[name contract_digest risk effect attempts])
      selected["contract_digest"] = Harness.valid_digest!(selected.fetch("contract_digest"))
      selected["name"] = required_receipt_text(selected["name"], "tool name")
      selected["attempts"] = Integer(selected["attempts"]) if selected["attempts"]
      raise ArgumentError, "tool attempts cannot be negative" if selected.fetch("attempts", 0).negative?

      Harness.deep_freeze(selected)
    end
    private_class_method :tool_receipt

    def verification_receipt(item)
      data = receipt_hash(item)
      selected = select_receipt_fields(
        data, %w[gate_id criterion_id status verdict source evidence_digest review_digest checked_at]
      )
      %w[evidence_digest review_digest].each do |name|
        selected[name] = Harness.valid_digest!(selected[name]) if selected[name]
      end
      selected.empty? ? nil : Harness.deep_freeze(selected)
    end
    private_class_method :verification_receipt

    def reference_receipt(item, label)
      return nil if item.nil?

      data = receipt_hash(item)
      value = select_receipt_fields(data, %w[reference digest])
      value["reference"] = required_receipt_text(value["reference"], "#{label} reference")
      value["digest"] = Harness.valid_digest!(value.fetch("digest"))
      Harness.deep_freeze(value)
    end
    private_class_method :reference_receipt

    def scalar_metadata(value)
      receipt_hash(value).first(32).to_h.each_with_object({}) do |(key, item), result|
        next unless scalar?(item)

        result[key.to_s] = item.is_a?(Symbol) ? item.to_s : item
      end.then { |data| Harness.deep_freeze(data) }
    end
    private_class_method :scalar_metadata

    def scalar_fields(value, fields)
      data = receipt_hash(value)
      fields.each_with_object({}) do |field, result|
        item = data[field]
        next unless data.key?(field) && scalar?(item)

        result[field] = item.is_a?(Symbol) ? item.to_s : item
      end.then { |result| Harness.deep_freeze(result) }
    end
    private_class_method :scalar_fields

    def scalar?(value)
      value.nil? || value.is_a?(Numeric) || value == true || value == false ||
        value.is_a?(String) || value.is_a?(Symbol)
    end
    private_class_method :scalar?

    def bounded_texts(values)
      Array(values).first(MAX_EXECUTION_ITEMS).map do |value|
        required_receipt_text(value, "receipt reference")
      end.freeze
    end
    private_class_method :bounded_texts

    def receipt_hash(item)
      value = item.respond_to?(:to_h) ? item.to_h : item
      raise ArgumentError, "receipt item must be hash-like" unless value.is_a?(Hash)

      Harness.stringify_keys(value)
    end
    private_class_method :receipt_hash

    def select_receipt_fields(data, names)
      names.each_with_object({}) { |name, out| out[name] = data[name] if data.key?(name) }
    end
    private_class_method :select_receipt_fields

    def required_receipt_text(value, label)
      text = value.to_s.strip
      raise ArgumentError, "#{label} is required" if text.empty?
      raise ArgumentError, "#{label} is too long" if text.bytesize > 512

      text
    end
    private_class_method :required_receipt_text
  end


  module Harness
    module Receipt
      module_function

      def build(progress, approvals: [], risks: [])
        Agentkit::Receipt.harness(progress, approvals: approvals, risks: risks)
      end

      def execution(**options)
        Agentkit::Receipt.execution(**options)
      end
    end
  end
end
