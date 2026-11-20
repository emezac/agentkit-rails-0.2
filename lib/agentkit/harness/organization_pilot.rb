# frozen_string_literal: true

module Agentkit
  module Harness
    module Organization
      # P3 adapter from a unique P2 recommendation to the existing durable,
      # independently reviewed two-arm business experiment. The pilot resolves
      # approved topology objects for host execution but never instantiates,
      # routes to or promotes an agent by itself.
      class CompositionPilot
        attr_reader :study, :recommendation, :experiment

        def initialize(study:, recommendation:, version:, unit:, metrics:,
                       primary_metric:, starts_at:, enrollment_ends_at:,
                       analysis_at:, window_seconds:, max_units:, min_per_arm:,
                       gates:, measurement_versions:, journal:, authorize:,
                       eligible:, bind_unit:, clock: -> { Time.now.utc })
          @study = study
          @recommendation = recommendation
          validate_recommendation!
          evidence_versions = normalize_evidence_versions(measurement_versions)
          @experiment = Knowledge::BusinessExperiment.new(
            name: "organization:#{study.id}",
            version: version,
            hypothesis: "approved composition improves #{study.workload.id}",
            unit: unit,
            metrics: metrics,
            primary_metric: primary_metric,
            starts_at: starts_at,
            enrollment_ends_at: enrollment_ends_at,
            analysis_at: analysis_at,
            window_seconds: window_seconds,
            max_units: max_units,
            min_per_arm: min_per_arm,
            gates: gates,
            variants: {
              "control" => variant("baseline", study.baseline_digest),
              "treatment" => variant("candidate", recommendation.selected_digest)
            },
            evidence_versions: evidence_versions,
            journal: journal,
            authorize: authorize,
            eligible: eligible,
            bind_unit: bind_unit,
            clock: clock
          )
        end

        def digest = experiment.digest
        def protocol = experiment.protocol

        def register(context:) = experiment.register(context: context)
        def approve(reason:, context:) = experiment.approve(reason: reason, context: context)
        def assign(unit_id:, context:) = experiment.assign(unit_id: unit_id, context: context)

        # Execution still crosses the caller-provided DecisionGate. The block
        # receives the assigned arm and immutable topology; it remains the only
        # place where host routing or domain effects may occur.
        def execute(unit_id:, gate:, arguments:, context:)
          raise ArgumentError, "composition pilot execution requires a block" unless block_given?

          experiment.execute(
            unit_id: unit_id, gate: gate, arguments: arguments, context: context
          ) do |arm, variant|
            yield arm, topology!(variant.fetch("topology_digest"))
          end
        end

        def outcome(unit_id:, values:, source:, source_version:, observed_at:, context:)
          experiment.outcome(
            unit_id: unit_id, values: values, source: source,
            source_version: source_version, observed_at: observed_at, context: context
          )
        end

        # This is the pilot kill switch. It blocks all later assignments and
        # executions; domain compensation for effects already committed remains
        # the responsibility of the host DecisionGate.
        def stop(reason:, context:) = experiment.stop(reason: reason, context: context)
        def analyze(context:) = experiment.analyze(context: context)

        def fetch(type:, context:, unit_id: nil)
          experiment.fetch(type: type, context: context, unit_id: unit_id)
        end

        def review_result(approve:, reason:, context:)
          experiment.review_result(approve: approve, reason: reason, context: context)
        end

        def revoke_result(reason:, context:)
          experiment.revoke_result(reason: reason, context: context)
        end

        def to_h
          Harness.deep_freeze(
            "schema_version" => 1,
            "kind" => "organization_composition_pilot",
            "study_digest" => study.digest,
            "recommendation_digest" => recommendation.digest,
            "experiment_digest" => digest,
            "baseline_digest" => study.baseline_digest,
            "candidate_digest" => recommendation.selected_digest,
            "scope" => recommendation.scope,
            "auto_promoted" => false,
            "authorizes" => false
          )
        end

        private

        def validate_recommendation!
          unless study.is_a?(CompositionStudy) &&
                 recommendation.is_a?(CompositionRecommendation)
            raise HarnessExperimentError,
              "composition pilot requires a study and recommendation"
          end
          unless recommendation.status == "recommend_review" &&
                 recommendation.requires_review? &&
                 !recommendation.auto_promoted? &&
                 !recommendation.authorizes?
            raise PolicyDenied, "composition pilot requires one reviewable P2 candidate"
          end
          unless Harness.secure_equal?(recommendation.study_digest, study.digest) &&
                 Harness.secure_equal?(recommendation.digest, study.recommend.digest)
            raise HarnessIntegrityError, "composition recommendation is stale or foreign"
          end
          unless study.candidate_digests.include?(recommendation.selected_digest)
            raise HarnessIntegrityError, "composition recommendation selected an unknown topology"
          end
        end

        def normalize_evidence_versions(values)
          supplied = DeclarativeData.normalize(
            values || {}, label: "pilot measurement versions",
            error_class: HarnessExperimentError
          )
          unless supplied.is_a?(Hash) && supplied.any? &&
                 supplied.values.all? { |value| value.is_a?(String) && !value.empty? }
            raise HarnessExperimentError,
              "composition pilot requires versioned measurement dependencies"
          end
          Harness.deep_freeze(supplied.merge(
            "composition_study" => study.digest,
            "composition_recommendation" => recommendation.digest,
            "training_report" => study.training_report.digest,
            "holdout_report" => study.holdout_report.digest
          ))
        end

        def variant(role, topology_digest)
          Harness.deep_freeze(
            "role" => role,
            "topology_digest" => topology_digest,
            "study_digest" => study.digest,
            "recommendation_digest" => recommendation.digest
          )
        end

        def topology!(topology_digest)
          study.topologies.find { |topology| topology.digest == topology_digest } ||
            raise(HarnessIntegrityError, "pilot assignment references an unknown topology")
        end
      end
    end
  end
end
