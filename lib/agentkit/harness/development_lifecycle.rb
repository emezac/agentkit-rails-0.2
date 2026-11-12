# frozen_string_literal: true

module Agentkit
  module Harness
    # A proposed replacement for an immutable Goal. Revisions never mutate the
    # original contract and material changes require an explicitly authorized
    # approval before they can be applied to in-flight progress.
    class GoalRevision
      CHANGE_KEYS = %w[
        objective criteria constraints scope protected_resources
        required_approvals required_outputs max_steps metadata
      ].freeze

      attr_reader :base_goal, :revised_goal, :reason, :proposed_by, :proposed_at,
                  :changed_fields, :approval_reasons, :approval

      def self.propose(progress: nil, goal: nil, changes:, reason:, proposed_by:)
        current = progress&.goal || goal
        raise ArgumentError, "progress or goal is required" unless current.is_a?(Goal)

        new(
          base_goal: current, changes: changes, reason: reason,
          proposed_by: proposed_by
        )
      end

      def initialize(base_goal:, changes:, reason:, proposed_by:, proposed_at: Time.now.utc)
        @base_goal = base_goal
        @reason = required_text(reason, "revision reason")
        @proposed_by = required_text(proposed_by, "revision proposer")
        @proposed_at = Harness.time(proposed_at)
        normalized_changes = Harness.stringify_keys(changes || {})
        unknown = normalized_changes.keys - CHANGE_KEYS
        raise ArgumentError, "unknown goal revision fields: #{unknown.join(', ')}" if unknown.any?
        raise ArgumentError, "goal revision requires at least one change" if normalized_changes.empty?

        attributes = base_goal.to_h.merge(normalized_changes).merge("id" => base_goal.id)
        @revised_goal = Goal.from_h(attributes)
        @changed_fields = CHANGE_KEYS.select do |key|
          Harness.digest(base_goal.to_h[key]) != Harness.digest(revised_goal.to_h[key])
        end.freeze
        raise ArgumentError, "goal revision does not change the contract" if changed_fields.empty?

        @approval_reasons = calculate_approval_reasons.freeze
        @approval = nil
      end

      def digest
        @digest ||= Harness.digest(
          "base_goal_digest" => base_goal.digest,
          "revised_goal_digest" => revised_goal.digest,
          "reason" => reason,
          "proposed_by" => proposed_by,
          "proposed_at" => proposed_at.iso8601(6),
          "changed_fields" => changed_fields,
          "approval_reasons" => approval_reasons
        ).freeze
      end

      def approval_required? = approval_reasons.any?
      def approved? = !approval_required? || approval&.fetch("status") == "approved"

      # Authorization belongs to the host. The callback receives only a frozen,
      # redacted request and must return exactly true; absence/failure denies.
      def approve!(actor:, evidence_ref:, authorize:)
        raise HarnessError, "this goal revision does not require approval" unless approval_required?
        raise HarnessError, "goal revision is already approved" if approval
        raise PolicyDenied, "goal revision approval requires an authorizer" unless authorize.respond_to?(:call)

        reviewer = required_text(actor, "revision approver")
        reference = required_text(evidence_ref, "approval evidence reference")
        request = Harness.deep_freeze(
          "revision_digest" => digest,
          "base_goal_digest" => base_goal.digest,
          "revised_goal_digest" => revised_goal.digest,
          "actor" => reviewer,
          "approval_reasons" => approval_reasons
        )
        allowed = authorize.arity.zero? ? authorize.call : authorize.call(request)
        raise PolicyDenied, "goal revision approval was denied" unless allowed == true

        @approval = Harness.deep_freeze(
          "status" => "approved",
          "actor" => reviewer,
          "evidence_ref" => reference,
          "evidence_digest" => Harness.digest(reference),
          "approved_revision_digest" => digest,
          "approved_at" => Time.now.utc.iso8601(6)
        )
        self
      end

      def apply(progress, context: nil)
        raise ArgumentError, "progress must be an Agentkit::Harness::Progress" unless progress.is_a?(Progress)
        unless Harness.secure_equal?(progress.goal.digest, base_goal.digest)
          raise HarnessIntegrityError, "goal revision base does not match current progress"
        end
        raise HarnessError, "completed or failed progress cannot be revised" if %w[completed failed].include?(progress.status)
        raise PolicyDenied, "goal revision requires approval" unless approved?
        if progress.step_count > revised_goal.max_steps
          raise HarnessIntegrityError, "revised goal max_steps is below the steps already used"
        end

        invalidates_all = (changed_fields & %w[objective scope protected_resources]).any?
        old_requirements = requirements_by_id(base_goal)
        new_requirements = requirements_by_id(revised_goal)
        retained = {}
        carried = []
        stale = []

        progress.evidence.each do |id, item|
          reason_code = invalidation_reason(id, old_requirements, new_requirements, invalidates_all)
          if reason_code
            stale << stale_evidence(item, reason_code)
          else
            retained[id] = item
            carried << { "criterion_id" => id, "evidence_digest" => item.digest }
          end
        end

        retained_outputs = if invalidates_all
                             {}
                           else
                             progress.outputs.select { |name, _| revised_goal.required_outputs.include?(name) }
                           end
        stale_outputs = progress.outputs.reject { |name, _| retained_outputs.key?(name) }.map do |name, item|
          { "name" => name, "digest" => item["digest"], "reason" => "goal_contract_changed" }
        end

        retain_approvals = changed_fields == ["metadata"]
        retained_approvals = retain_approvals ? progress.approvals : {}
        stale_approvals = progress.approvals.reject { |name, _| retained_approvals.key?(name) }.map do |name, item|
          { "name" => name, "evidence_digest" => item["evidence_digest"], "reason" => "goal_revised" }.compact
        end

        decision = {
          "summary" => "applied goal revision #{digest}",
          "source" => "agentkit:goal_revision",
          "at" => Time.now.utc.iso8601(6)
        }
        revised_progress = Progress.new(
          goal: revised_goal,
          status: progress.status == "pending" ? "pending" : "running",
          step_count: progress.step_count,
          outputs: retained_outputs,
          evidence: retained,
          approvals: retained_approvals,
          decisions: progress.decisions + [decision],
          lessons: progress.lessons,
          open_issues: progress.open_issues,
          next_action: progress.next_action,
          created_at: progress.created_at,
          updated_at: Time.now.utc
        )
        result = RevisionResult.new(
          revision: self, progress: revised_progress,
          carried_evidence: carried, invalidated_evidence: stale,
          invalidated_outputs: stale_outputs, invalidated_approvals: stale_approvals
        )
        record_application(result, context || Context.resolve)
        result
      end

      def to_h
        Harness.deep_freeze(
          "revision_digest" => digest,
          "base_goal_digest" => base_goal.digest,
          "revised_goal_digest" => revised_goal.digest,
          "reason" => reason,
          "proposed_by" => proposed_by,
          "proposed_at" => proposed_at.iso8601(6),
          "changed_fields" => changed_fields,
          "approval_reasons" => approval_reasons,
          "approval" => approval
        )
      end

      private

      def calculate_approval_reasons
        reasons = []
        reasons << "objective_changed" if changed_fields.include?("objective")
        reasons << "requirements_changed" if (changed_fields & %w[criteria constraints]).any?
        reasons << "scope_changed" if changed_fields.include?("scope")
        reasons << "protected_resources_changed" if changed_fields.include?("protected_resources")
        reasons << "approval_policy_changed" if changed_fields.include?("required_approvals")
        reasons << "required_outputs_changed" if changed_fields.include?("required_outputs")
        reasons << "step_budget_changed" if changed_fields.include?("max_steps")
        reasons
      end

      def requirements_by_id(goal)
        (goal.criteria + goal.constraints).to_h { |item| [item.id, item.to_h] }
      end

      def invalidation_reason(id, old_requirements, new_requirements, invalidates_all)
        return "goal_context_changed" if invalidates_all
        return "requirement_removed" unless new_requirements.key?(id)
        return "requirement_changed" unless Harness.secure_equal?(
          Harness.digest(old_requirements[id]), Harness.digest(new_requirements[id])
        )

        nil
      end

      def stale_evidence(item, reason_code)
        {
          "criterion_id" => item.criterion_id,
          "verdict" => item.verdict,
          "source" => item.source,
          "evidence_digest" => item.digest,
          "reason" => reason_code,
          "invalidated_by" => digest,
          "invalidated_at" => Time.now.utc.iso8601(6)
        }.compact
      end

      def record_application(result, context)
        Agentkit.with_context(context) do
          Audit.record(
            event_type: "harness.goal_revision.applied",
            agent_name: "Agentkit::Harness",
            status: "applied",
            payload: result.to_h,
            context: context
          )
          Telemetry.emit(
            "harness.goal_revision.applied",
            dims: { goal_id: revised_goal.id, approval_required: approval_required? },
            measures: {
              changed_fields: changed_fields.size,
              carried_evidence: result.carried_evidence.size,
              invalidated_evidence: result.invalidated_evidence.size,
              invalidated_outputs: result.invalidated_outputs.size
            }
          )
        end
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise ArgumentError, "#{label} is required" if text.empty?

        text.freeze
      end
    end

    class RevisionResult
      attr_reader :revision, :progress, :carried_evidence, :invalidated_evidence,
                  :invalidated_outputs, :invalidated_approvals

      def initialize(revision:, progress:, carried_evidence:, invalidated_evidence:,
                     invalidated_outputs:, invalidated_approvals:)
        @revision = revision
        @progress = progress
        @carried_evidence = Harness.deep_freeze(carried_evidence)
        @invalidated_evidence = Harness.deep_freeze(invalidated_evidence)
        @invalidated_outputs = Harness.deep_freeze(invalidated_outputs)
        @invalidated_approvals = Harness.deep_freeze(invalidated_approvals)
        freeze
      end

      def to_h
        Harness.deep_freeze(
          "revision" => revision.to_h,
          "goal_id" => progress.goal.id,
          "new_goal_digest" => progress.goal.digest,
          "carried_evidence" => carried_evidence,
          "invalidated_evidence" => invalidated_evidence,
          "invalidated_outputs" => invalidated_outputs,
          "invalidated_approvals" => invalidated_approvals
        )
      end
    end

    # Immutable definition of a deterministic host-owned verification gate.
    # AgentKit records evidence; it deliberately does not run shell commands.
    class VerificationGate
      STATUSES = %w[passed failed pending].freeze
      attr_reader :id, :description, :required, :metadata

      def initialize(id:, description:, required: true, metadata: {})
        @id = required_text(id, "verification gate id")
        @description = required_text(description, "verification gate description")
        @required = !!required
        @metadata = Harness.deep_freeze(Harness.stringify_keys(metadata || {}))
        JSON.generate(to_h)
        freeze
      rescue JSON::GeneratorError => e
        raise ArgumentError, "verification gate must be JSON serializable: #{e.message}"
      end

      def required? = required
      def digest = Harness.digest(to_h)

      def record(status:, commit_sha:, source: nil, value: nil, evidence_digest: nil,
                 configuration_digest: nil, dependencies_digest: nil, checked_at: Time.now.utc)
        VerificationResult.new(
          gate_id: id, gate_digest: digest, status: status, commit_sha: commit_sha,
          source: source, value: value, evidence_digest: evidence_digest,
          configuration_digest: configuration_digest,
          dependencies_digest: dependencies_digest, checked_at: checked_at
        )
      end

      def to_h
        { "id" => id, "description" => description, "required" => required, "metadata" => metadata }
      end

      private

      def required_text(value, label)
        text = value.to_s.strip
        raise ArgumentError, "#{label} is required" if text.empty?

        text.freeze
      end
    end

    class VerificationResult
      attr_reader :gate_id, :gate_digest, :status, :commit_sha, :source,
                  :evidence_digest, :configuration_digest, :dependencies_digest,
                  :checked_at

      def initialize(gate_id:, gate_digest:, status:, commit_sha:, source: nil, value: nil,
                     evidence_digest: nil, configuration_digest: nil,
                     dependencies_digest: nil, checked_at: Time.now.utc)
        @gate_id = required_text(gate_id, "verification gate id")
        @gate_digest = Harness.valid_digest!(gate_digest).freeze
        @status = status.to_s
        raise ArgumentError, "unknown verification status: #{status.inspect}" unless
          VerificationGate::STATUSES.include?(@status)

        @commit_sha = self.class.normalize_commit_sha(commit_sha)
        @source = source&.to_s&.strip
        if %w[passed failed].include?(@status) && @source.to_s.empty?
          raise ArgumentError, "verification source is required for #{@status} results"
        end
        @evidence_digest = if @status == "pending" && evidence_digest.nil? && value.nil?
                             nil
                           else
                             Harness.valid_digest!(
                               evidence_digest || Harness.digest(value.nil? ? @source : value)
                             ).freeze
                           end
        @configuration_digest = optional_digest(configuration_digest)
        @dependencies_digest = optional_digest(dependencies_digest)
        @checked_at = Harness.time(checked_at)
        freeze
      end

      def passed? = status == "passed"

      def to_h
        {
          "gate_id" => gate_id,
          "gate_digest" => gate_digest,
          "status" => status,
          "commit_sha" => commit_sha,
          "source" => source,
          "evidence_digest" => evidence_digest,
          "configuration_digest" => configuration_digest,
          "dependencies_digest" => dependencies_digest,
          "checked_at" => checked_at.iso8601(6)
        }.compact
      end

      def self.normalize_commit_sha(value)
        sha = value.to_s.strip.downcase
        raise ArgumentError, "commit_sha must be a full 40 or 64 character hexadecimal digest" unless
          sha.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)

        sha.freeze
      end

      private

      def optional_digest(value)
        value.nil? ? nil : Harness.valid_digest!(value).freeze
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise ArgumentError, "#{label} is required" if text.empty?

        text.freeze
      end
    end

    # Redacted, immutable release-candidate snapshot. It binds completion,
    # artifact and host verification evidence to one exact commit; it grants no
    # deployment permission and performs no side effect.
    class ReleaseCandidateReceipt
      attr_reader :data

      def self.build(progress:, commit_sha:, gates:, results:, artifact_reference:,
                     artifact_digest:, deployment_plan_reference:, deployment_plan_digest:,
                     rollback_plan_reference:, rollback_plan_digest:, revision: nil)
        new(
          progress: progress, commit_sha: commit_sha, gates: gates, results: results,
          artifact_reference: artifact_reference, artifact_digest: artifact_digest,
          deployment_plan_reference: deployment_plan_reference,
          deployment_plan_digest: deployment_plan_digest,
          rollback_plan_reference: rollback_plan_reference,
          rollback_plan_digest: rollback_plan_digest, revision: revision
        )
      end

      def initialize(progress:, commit_sha:, gates:, results:, artifact_reference:,
                     artifact_digest:, deployment_plan_reference:, deployment_plan_digest:,
                     rollback_plan_reference:, rollback_plan_digest:, revision: nil)
        raise ArgumentError, "progress must be an Agentkit::Harness::Progress" unless progress.is_a?(Progress)

        sha = VerificationResult.normalize_commit_sha(commit_sha)
        definitions = Array(gates)
        unless definitions.all? { |gate| gate.is_a?(VerificationGate) }
          raise ArgumentError, "gates must contain Agentkit::Harness::VerificationGate values"
        end
        raise ArgumentError, "at least one verification gate is required" if definitions.empty?

        duplicate_gate_ids = definitions.group_by(&:id).select { |_, items| items.size > 1 }.keys
        raise ArgumentError, "duplicate verification gate ids: #{duplicate_gate_ids.join(', ')}" if duplicate_gate_ids.any?

        supplied_results = Array(results)
        unless supplied_results.all? { |item| item.is_a?(VerificationResult) }
          raise ArgumentError, "results must contain Agentkit::Harness::VerificationResult values"
        end
        duplicate_result_ids = supplied_results.group_by(&:gate_id).select { |_, items| items.size > 1 }.keys
        raise ArgumentError, "duplicate verification result ids: #{duplicate_result_ids.join(', ')}" if duplicate_result_ids.any?
        unknown = supplied_results.map(&:gate_id) - definitions.map(&:id)
        raise ArgumentError, "results contain unknown verification gates: #{unknown.join(', ')}" if unknown.any?

        if revision && (!revision.is_a?(GoalRevision) ||
          !Harness.secure_equal?(revision.revised_goal.digest, progress.goal.digest))
          raise HarnessIntegrityError, "release candidate revision does not match progress goal"
        end

        by_id = supplied_results.to_h { |item| [item.gate_id, item] }
        gate_entries = definitions.map { |gate| gate_entry(gate, by_id[gate.id], sha) }
        evaluation = progress.evaluate!
        candidate_ready = evaluation.complete? && gate_entries.select { |item| item["required"] }
                                                              .all? { |item| item["status"] == "passed" }
        value = {
          "schema" => "agentkit.release_candidate.v1",
          "kind" => "release_candidate",
          "goal_id" => progress.goal.id,
          "goal_digest" => progress.goal.digest,
          "goal_revision_digest" => revision&.digest,
          "commit_sha" => sha,
          "status" => candidate_ready ? "ready" : "blocked",
          "ready" => candidate_ready,
          "progress_status" => progress.status,
          "artifact" => {
            "reference" => required_text(artifact_reference, "artifact reference"),
            "digest" => Harness.valid_digest!(artifact_digest)
          },
          "verification_gates" => gate_entries,
          "deployment_plan" => {
            "reference" => required_text(deployment_plan_reference, "deployment plan reference"),
            "digest" => Harness.valid_digest!(deployment_plan_digest)
          },
          "rollback_plan" => {
            "reference" => required_text(rollback_plan_reference, "rollback plan reference"),
            "digest" => Harness.valid_digest!(rollback_plan_digest)
          },
          "missing_requirements" => evaluation.missing_criteria + evaluation.missing_constraints,
          "missing_outputs" => evaluation.missing_outputs,
          "missing_approvals" => evaluation.missing_approvals,
          "generated_at" => Time.now.utc.iso8601(6)
        }.compact
        value["receipt_digest"] = Harness.digest(value)
        @data = Harness.deep_freeze(value)
        freeze
      end

      def ready? = data["ready"]
      def digest = data["receipt_digest"]
      def [](key) = data[key.to_s]
      def to_h = data

      private

      def gate_entry(gate, result, commit_sha)
        base = gate.to_h.merge("gate_digest" => gate.digest)
        return base.merge("status" => "pending", "reason" => "missing_result") unless result
        unless Harness.secure_equal?(gate.digest, result.gate_digest)
          return base.merge("status" => "stale", "reason" => "gate_contract_changed",
                            "evidence_digest" => result.evidence_digest)
        end
        unless Harness.secure_equal?(commit_sha, result.commit_sha)
          return base.merge("status" => "stale", "reason" => "commit_mismatch",
                            "evidence_digest" => result.evidence_digest,
                            "verified_commit_sha" => result.commit_sha)
        end

        base.merge(result.to_h)
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise ArgumentError, "#{label} is required" if text.empty?

        text
      end
    end
  end
end
