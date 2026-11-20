# frozen_string_literal: true

module Agentkit
  module Harness
    module Organization
      # P4: durable, human-controlled adoption of a P3 result. It reuses the
      # exploration review/binding store for locking, generations and rollback,
      # but owns separate evidence validation and an organization target prefix.
      module CompositionGovernance
        TARGET_PREFIX = "organization:"

        module_function

        def submit!(target:, pilot:, context: Context.resolve)
          unless pilot.is_a?(CompositionPilot)
            raise HarnessExperimentError, "organization review requires a CompositionPilot"
          end
          resolved_scope = Scope.resolve(context: context)
          validate_scope!(pilot, resolved_scope)
          analysis, final_review = validated_pilot_evidence!(pilot, context)
          namespaced = target_name(target)
          active = store.binding(namespaced, scope: resolved_scope)
          if active && !Harness.secure_equal?(active.policy_digest, pilot.study.baseline_digest)
            raise DecisionConflict,
              "active organization differs from the pilot baseline; run a new study"
          end

          baseline = pilot.study.topologies.find do |topology|
            topology.digest == pilot.study.baseline_digest
          end
          candidate = pilot.study.topologies.find do |topology|
            topology.digest == pilot.recommendation.selected_digest
          end
          raise HarnessIntegrityError, "pilot topology evidence is incomplete" unless baseline && candidate

          evidence = Harness.deep_freeze(
            "schema_version" => 1,
            "level" => "organization",
            "kind" => "composition_pilot_result",
            "scope" => scope_data(resolved_scope),
            "pilot_digest" => pilot.digest,
            "study_digest" => pilot.study.digest,
            "recommendation_digest" => pilot.recommendation.digest,
            "analysis_digest" => Knowledge.digest(analysis),
            "final_review_digest" => Knowledge.digest(final_review),
            "final_reviewer" => final_review.fetch("actor"),
            "baseline_digest" => pilot.study.baseline_digest,
            "candidate_digest" => pilot.recommendation.selected_digest,
            "auto_promoted" => false
          )
          review = Exploration::Governance::Review.new(
            id: SecureRandom.uuid,
            target: namespaced,
            status: "pending",
            tenant_key: resolved_scope.tenant_key || "__global__",
            account_id: resolved_scope.account_id,
            incumbent_name: active&.policy_name || baseline.id,
            incumbent_version: active&.policy_version || pilot.study.digest,
            incumbent_digest: active&.policy_digest || baseline.digest,
            candidate_name: candidate.id,
            candidate_version: pilot.study.digest,
            candidate_digest: candidate.digest,
            evidence_digest: Harness.digest(evidence),
            evidence: evidence,
            submitted_at: Time.now.utc,
            previous_binding: {}
          ).freeze
          store.submit(review) do |persisted|
            audit!("submitted", persisted, context: context)
          end.tap { emit("submitted", context) }
        end

        def approve!(review, actor:, reason:, authorize:, context: Context.resolve)
          transition(:approve, review, actor: actor, reason: reason,
                     authorize: authorize, context: context)
        end

        def reject!(review, actor:, reason:, authorize:, context: Context.resolve)
          transition(:reject, review, actor: actor, reason: reason,
                     authorize: authorize, context: context)
        end

        def rollback!(review, actor:, reason:, authorize:, context: Context.resolve)
          transition(:rollback, review, actor: actor, reason: reason,
                     authorize: authorize, context: context)
        end

        def find(id, context: Context.resolve)
          scope = Scope.resolve(context: context)
          review = store.find(id, scope: scope)
          organization_review(review)
        end

        def reviews(context: Context.resolve, status: nil, limit: 100)
          scope = Scope.resolve(context: context)
          maximum = [[Integer(limit), 1].max, 200].min
          store.all(scope: scope, status: status, limit: maximum).filter_map do |review|
            organization_review(review)
          end
        rescue ArgumentError, TypeError
          raise HarnessExperimentError, "organization review limit must be an integer"
        end

        def binding(target:, context: Context.resolve)
          store.binding(target_name(target), scope: Scope.resolve(context: context))
        end

        # Resolution is read-only. The host authorizer and resolver are checked
        # on every call so a stale registry entry cannot silently become active.
        def resolve(target:, resolver:, authorize:, context: Context.resolve)
          raise PolicyDenied, "organization resolution requires a resolver" unless resolver.respond_to?(:call)

          active = binding(target: target, context: context)
          raise HarnessIntegrityError, "organization binding is not active" unless active

          request = Harness.deep_freeze(
            "action" => "resolve_organization",
            "target" => target_name(target),
            "topology_digest" => active.policy_digest,
            "binding_generation" => active.generation,
            "review_id" => active.review_id
          )
          authorize!("resolve_organization", request, authorize, context)
          topology = resolver.call(active.policy_digest, context)
          unless topology.is_a?(Topology) && Harness.secure_equal?(topology.digest, active.policy_digest)
            raise HarnessIntegrityError, "organization resolver returned a stale topology"
          end
          Agentkit.with_context(context) do
            Telemetry.emit(
              "organization.binding.resolved",
              dims: { target: target_name(target), topology_digest: active.policy_digest },
              measures: { generation: active.generation }
            )
          end
          topology
        rescue PolicyDenied, HarnessIntegrityError
          raise
        rescue StandardError => error
          raise HarnessIntegrityError, "organization resolution failed (#{error.class.name})"
        end

        def store = Exploration::Governance.store

        def transition(operation, review, actor:, reason:, authorize:, context:)
          resolved_scope = Scope.resolve(context: context)
          current = owned_review!(review, resolved_scope)
          principal = required_text(actor, "organization reviewer")
          explanation = required_text(reason, "organization review reason", maximum: 2_000)
          final_reviewer = current.evidence.fetch("final_reviewer")
          if operation == :approve && principal == final_reviewer
            raise PolicyDenied, "organization adoption requires a reviewer independent from the pilot"
          end
          request = Harness.deep_freeze(
            "action" => "#{operation}_organization",
            "review_id" => current.id,
            "target" => current.target,
            "incumbent_digest" => current.incumbent_digest,
            "candidate_digest" => current.candidate_digest,
            "evidence_digest" => current.evidence_digest,
            "actor" => principal
          )
          authorize!(request.fetch("action"), request, authorize, context)
          event = { approve: "approved", reject: "rejected", rollback: "rolled_back" }.fetch(operation)
          store.public_send(
            operation, current.id, actor: principal, reason: explanation,
            scope: resolved_scope
          ) do |persisted, active|
            audit!(event, persisted, binding: active, context: context)
          end.tap { emit(event, context) }
        end
        private_class_method :transition

        def validated_pilot_evidence!(pilot, context)
          analysis = pilot.fetch(type: "analysis", context: context)
          final_review = pilot.fetch(type: "final_review", context: context)
          revocation = pilot.fetch(type: "revocation", context: context)
          unless analysis.is_a?(Hash) && analysis["status"] == "eligible_for_human_review" &&
                 final_review.is_a?(Hash) && final_review["approved"] == true &&
                 final_review["auto_promoted"] == false && revocation.nil? &&
                 Harness.secure_equal?(final_review["report_digest"], Knowledge.digest(analysis))
            raise PolicyDenied,
              "organization adoption requires an approved, unrevoked P3 analysis"
          end

          [analysis, final_review]
        end
        private_class_method :validated_pilot_evidence!

        def validate_scope!(pilot, scope)
          unless pilot.recommendation.scope == scope_data(scope)
            raise HarnessIntegrityError, "organization pilot scope mismatch"
          end
        end
        private_class_method :validate_scope!

        def owned_review!(value, scope)
          id = value.respond_to?(:id) ? value.id : value
          organization_review(store.find(id, scope: scope)) ||
            raise(HarnessIntegrityError, "organization review not found")
        end
        private_class_method :owned_review!

        def organization_review(review)
          return unless review && review.target.start_with?(TARGET_PREFIX) &&
                        review.evidence["level"] == "organization"

          review
        end
        private_class_method :organization_review

        def authorize!(action, request, callback, context)
          raise PolicyDenied, "organization governance requires an authorizer" unless callback.respond_to?(:call)

          allowed = callback.call(action, request, context)
          raise PolicyDenied, "organization governance authorization was denied" unless allowed == true
        rescue PolicyDenied
          raise
        rescue StandardError => error
          raise PolicyDenied, "organization governance authorization failed (#{error.class.name})"
        end
        private_class_method :authorize!

        def audit!(event, review, binding: nil, context:)
          Agentkit.with_context(context) do
            Audit.record(
              event_type: "organization.review.#{event}",
              status: review.status,
              payload: {
                review_id: review.id,
                target: review.target,
                incumbent_digest: review.incumbent_digest,
                candidate_digest: review.candidate_digest,
                evidence_digest: review.evidence_digest,
                reviewed_by: review.reviewed_by,
                reason: review.review_reason,
                active_binding_digest: binding&.policy_digest,
                binding_generation: binding&.generation
              }.compact,
              context: context,
              failure_mode: :required
            )
          end
        end
        private_class_method :audit!

        def emit(status, context)
          Agentkit.with_context(context) do
            Telemetry.emit(
              "organization.review.transition",
              dims: { status: status }, measures: { count: 1 }
            )
          end
        end
        private_class_method :emit

        def target_name(value)
          name = Organization.identifier!(value, "organization target")
          "#{TARGET_PREFIX}#{name}"
        end
        private_class_method :target_name

        def required_text(value, label, maximum: 256)
          text = value.to_s.strip
          unless text.bytesize.between?(1, maximum) && !text.match?(/[[:cntrl:]]/)
            raise HarnessExperimentError, "#{label} must contain 1..#{maximum} safe bytes"
          end

          text.freeze
        end
        private_class_method :required_text

        def scope_data(scope)
          { "tenant_key" => scope.tenant_key || "__global__", "account_id" => scope.account_id }
        end
        private_class_method :scope_data
      end
    end
  end
end
