# frozen_string_literal: true

module Agentkit
  module Harness
    class ArchitectureEvaluation
      # Explicit persistence includes blocked evaluations, which never enter
      # promotion review. Digest-addressed reports reuse the existing Memory port.
      module Reports
        TYPE = "architecture_evaluation_report"
        module_function

        def record!(recommendation:, context: Context.resolve)
          details = recommendation.holdout
          unless recommendation.level == "harness" && details["architecture_evaluation"]
            raise HarnessExperimentError, "recommendation has no architecture evaluation"
          end
          unless details["scope"] == scope_for(context)
            raise HarnessIntegrityError, "architecture report scope mismatch"
          end
          payload = DeclarativeData.normalize({
            "schema_version" => 1, "phase" => "holdout", "scope" => details.fetch("scope"),
            "study_id" => details.fetch("study_id"), "study_digest" => details.fetch("study_digest"),
            "selected" => recommendation.selected, "status" => recommendation.status,
            "reason" => recommendation.reason, "architecture_evaluation" => details.fetch("architecture_evaluation"),
            "delegation_diagnostics" => details["delegation_diagnostics"],
            "comparison" => recommendation.comparison.to_h,
            "world_digests" => (recommendation.evaluations + recommendation.holdout_evaluations)
                              .map(&:world_digests).reduce({}, :merge)
          }, label: "architecture report")
          persist!(payload, context: context)
        end

        def record_training!(study:, training_worlds:)
          comparisons = study.training_architecture_report(training_worlds: training_worlds)
          selection = study.select(training_worlds: training_worlds)
          comparisons.map do |candidate, comparison|
            persist!({
              "schema_version" => 1, "phase" => "training", "scope" => scope_for(study.context),
              "study_id" => study.id, "study_digest" => study.digest, "selected" => candidate,
              "status" => comparison["allowed"] ? "training_passed" : "training_blocked",
              "reason" => comparison["allowed"] ? "architecture_training_passed" : "architecture_gate_failed",
              "selection_digest" => selection.evidence_digest,
              "architecture_evaluation" => { "policy" => study.architecture_evaluation.to_h, "training" => comparison },
              "delegation_diagnostics" => study.delegation_diagnostics&.to_h
            }, context: study.context)
          end.freeze
        end

        def persist!(value, context:)
          payload = DeclarativeData.normalize(value, label: "architecture report")
          unless payload["scope"] == scope_for(context)
            raise HarnessIntegrityError, "architecture report scope mismatch"
          end
          digest = Harness.digest(payload)
          report = Harness.deep_freeze(payload.merge("id" => digest))
          if JSON.generate(report).bytesize > context.config.harness.max_checkpoint_bytes
            raise HarnessPersistenceError, "architecture report exceeds checkpoint byte limit"
          end
          existing = all(context: context, limit: nil).find { |entry| entry["id"] == digest }
          return existing if existing
          Agentkit.with_context(context) do
            row = Memory.store(
              "Architecture evaluation #{digest}", type: TYPE, embed: false,
              retention: :durable, ontological_type: :imagined, context: context,
              metadata: { "architecture_report" => report, "digest" => Harness.digest(report) }
            )
            raise HarnessPersistenceError, "memory writes disabled" unless row
            Audit.record(event_type: "harness.architecture.evaluated",
                         payload: { report_id: digest, study_digest: payload["study_digest"],
                                    status: payload["status"] }, context: context)
            evaluation = report.fetch("architecture_evaluation").fetch(payload.fetch("phase"))
            Telemetry.emit("harness.architecture.evaluated", dims: { status: payload["status"] },
                           measures: { regressions: evaluation["regressions"] })
          end
          report
        end

        def all(context: Context.resolve, limit: 100)
          unless limit.nil? || (limit.is_a?(Integer) && limit.between?(1, 200))
            raise ArgumentError, "architecture report limit must be between 1 and 200"
          end
          scope = scope_for(context)
          rows = Agentkit.with_context(context) { Memory.all(types: [TYPE], ontological: :imagined) }
          reports = rows.select do |row|
            (row.tenant_key || "__global__").to_s == scope["tenant_key"].to_s &&
              row.account_id.to_s == scope["account_id"].to_s
          end.sort_by(&:created_at).reverse.map do |row|
            report = DeclarativeData.normalize(row.metadata.fetch("architecture_report"), label: "architecture report")
            unless row.metadata["digest"] == Harness.digest(report) && report["scope"] == scope &&
                   report["id"] == Harness.digest(report.reject { |key, _| key == "id" })
              raise HarnessIntegrityError, "architecture report integrity failure"
            end
            Harness.deep_freeze(report)
          end.uniq { |report| report["id"] }
          (limit ? reports.first(limit) : reports).freeze
        end

        def scope_for(context)
          scope = Scope.resolve(context: context)
          { "tenant_key" => scope.tenant_key || "__global__", "account_id" => scope.account_id }
        end
        private_class_method :scope_for
        private_class_method :persist!
      end
    end
  end
end
