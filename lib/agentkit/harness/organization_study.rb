# frozen_string_literal: true

module Agentkit
  module Harness
    module Organization
      # A redacted, immutable decision aid. It never grants authority to alter
      # routing, instantiate agents or activate the selected topology.
      class CompositionRecommendation
        STATUSES = %w[retain recommend_review needs_choice].freeze

        attr_reader :study_digest, :scope, :workload_digest, :baseline_digest,
                    :status, :selected_digest, :shortlist, :blockers,
                    :training_report_digest, :holdout_report_digest,
                    :approval_digest, :evidence_digest, :reason

        def initialize(study_digest:, scope:, workload_digest:, baseline_digest:,
                       status:, selected_digest:, shortlist:, blockers:,
                       training_report_digest:, holdout_report_digest:,
                       approval_digest:, evidence_digest:, reason:)
          @study_digest = Organization.digest!(study_digest, "study digest").freeze
          @scope = Organization.json_hash!(scope, "composition scope")
          @workload_digest = Organization.digest!(workload_digest, "workload digest").freeze
          @baseline_digest = Organization.digest!(baseline_digest, "baseline digest").freeze
          @status = status.to_s.freeze
          unless STATUSES.include?(@status)
            raise HarnessExperimentError, "unknown composition recommendation status"
          end
          @selected_digest = selected_digest &&
            Organization.digest!(selected_digest, "selected topology digest").freeze
          @shortlist = normalize_shortlist(shortlist)
          @blockers = Organization.json_hash!(blockers, "composition blockers")
          @training_report_digest = Organization.digest!(
            training_report_digest, "training report digest"
          ).freeze
          @holdout_report_digest = Organization.digest!(
            holdout_report_digest, "holdout report digest"
          ).freeze
          @approval_digest = Organization.digest!(approval_digest, "approval digest").freeze
          @evidence_digest = Organization.digest!(evidence_digest, "evidence digest").freeze
          @reason = Organization.identifier!(reason, "recommendation reason").freeze
          validate!
          freeze
        end

        def requires_review? = status != "retain"
        def auto_promoted? = false
        def authorizes? = false
        def digest = Harness.digest(to_h)

        def to_h
          Harness.deep_freeze(
            "schema_version" => 1,
            "kind" => "organization_composition_recommendation",
            "study_digest" => study_digest,
            "scope" => scope,
            "workload_digest" => workload_digest,
            "baseline_digest" => baseline_digest,
            "status" => status,
            "selected_digest" => selected_digest,
            "shortlist" => shortlist,
            "blockers" => blockers,
            "training_report_digest" => training_report_digest,
            "holdout_report_digest" => holdout_report_digest,
            "approval_digest" => approval_digest,
            "evidence_digest" => evidence_digest,
            "reason" => reason,
            "requires_review" => requires_review?,
            "auto_promoted" => auto_promoted?,
            "authorizes" => authorizes?
          )
        end

        private

        def normalize_shortlist(values)
          list = Array(values)
          if list.size > 32
            raise HarnessExperimentError, "composition shortlist exceeds bound"
          end
          Harness.deep_freeze(list.map do |value|
            data = Organization.json_hash!(value, "composition shortlist entry")
            {
              "topology_digest" => Organization.digest!(
                data.fetch("topology_digest"), "topology digest"
              ),
              "topology_id" => Organization.identifier!(data.fetch("topology_id"), "topology id"),
              "team_size" => Organization.integer!(data.fetch("team_size"), "team size", minimum: 1),
              "success_rate" => Organization.number!(
                data.fetch("success_rate"), "success rate", maximum: 1.0
              ),
              "mean_quality" => Organization.number!(
                data.fetch("mean_quality"), "mean quality", maximum: 1.0
              ),
              "mean_cost_usd" => Organization.number!(data.fetch("mean_cost_usd"), "mean cost"),
              "mean_latency_ms" => Organization.number!(data.fetch("mean_latency_ms"), "mean latency")
            }
          rescue KeyError => error
            raise HarnessExperimentError, "composition shortlist is missing #{error.key}"
          end.sort_by { |entry| entry.fetch("topology_digest") })
        end

        def validate!
          listed = shortlist.map { |entry| entry.fetch("topology_digest") }
          unless listed.uniq.size == listed.size
            raise HarnessExperimentError, "composition shortlist contains duplicate topologies"
          end
          if status == "recommend_review" && (!selected_digest || shortlist.size != 1 ||
             shortlist.first.fetch("topology_digest") != selected_digest)
            raise HarnessExperimentError, "review recommendation requires one selected topology"
          end
          if status != "recommend_review" && selected_digest
            raise HarnessExperimentError, "only a review recommendation may select a topology"
          end
          if status == "retain" && shortlist.any?
            raise HarnessExperimentError, "retain recommendation cannot contain a shortlist"
          end
          if status == "needs_choice" && shortlist.size < 2
            raise HarnessExperimentError, "choice recommendation requires competing topologies"
          end
        end
      end

      # P2: deterministic, governed comparison of pre-approved organizational
      # compositions over disjoint training and holdout evidence.
      class CompositionStudy
        MAX_PROFILES = 64

        attr_reader :id, :training_report, :holdout_report, :profiles,
                    :approved_topology_digests, :approval, :context, :scope,
                    :digest

        def initialize(id:, training_report:, holdout_report:, profiles:,
                       approved_topology_digests:, approved_by:,
                       approval_evidence_digest:, authorize:,
                       context: Context.resolve)
          @id = Organization.identifier!(id, "composition study id").freeze
          @training_report = report!(training_report, "training")
          @holdout_report = report!(holdout_report, "holdout")
          @context = context
          @scope = Scope.resolve(context: context)
          validate_reports!
          @profiles = normalize_profiles(profiles)
          @approved_topology_digests = normalize_approved(approved_topology_digests)
          baseline_reasons = profile_blockers(topology(baseline_digest))
          unless baseline_reasons.empty?
            raise HarnessExperimentError,
              "composition baseline lacks valid profile evidence: #{baseline_reasons.join(', ')}"
          end
          @approval = authorize_study!(
            approved_by: approved_by,
            evidence_digest: approval_evidence_digest,
            authorize: authorize
          )
          @digest = Harness.digest(identity).freeze
          freeze
        end

        def workload = training_report.workload
        def baseline_digest = training_report.baseline_digest
        def topologies = training_report.topologies
        def candidate_digests = topologies.map(&:digest).reject { |value| value == baseline_digest }.freeze

        def recommend
          blockers = candidate_digests.sort.to_h do |candidate_digest|
            [candidate_digest, candidate_blockers(candidate_digest)]
          end
          eligible = blockers.select { |_, reasons| reasons.empty? }.keys
          frontier = pareto_frontier(eligible)
          status, selected, reason = recommendation_state(frontier)
          recommendation = CompositionRecommendation.new(
            study_digest: digest,
            scope: scope_data,
            workload_digest: workload.digest,
            baseline_digest: baseline_digest,
            status: status,
            selected_digest: selected,
            shortlist: frontier.map { |candidate_digest| shortlist_entry(candidate_digest) },
            blockers: blockers,
            training_report_digest: training_report.digest,
            holdout_report_digest: holdout_report.digest,
            approval_digest: approval.fetch("digest"),
            evidence_digest: Harness.digest(
              "training" => training_report.evidence_digests,
              "holdout" => holdout_report.evidence_digests,
              "profiles" => profiles.values.map(&:digest).sort
            ),
            reason: reason
          )
          if JSON.generate(recommendation.to_h).bytesize > context.config.harness.max_checkpoint_bytes
            raise HarnessPersistenceError, "composition recommendation exceeds checkpoint byte limit"
          end
          recommendation
        end

        def to_h
          Harness.deep_freeze(
            "schema_version" => 1,
            "kind" => "organization_composition_study",
            "id" => id,
            "study_digest" => digest,
            "scope" => scope_data,
            "workload_digest" => workload.digest,
            "baseline_digest" => baseline_digest,
            "topology_digests" => topologies.map(&:digest).sort,
            "profile_digests" => profiles.transform_values(&:digest),
            "training_report_digest" => training_report.digest,
            "holdout_report_digest" => holdout_report.digest,
            "approval" => approval
          )
        end

        private

        def report!(value, label)
          return value if value.is_a?(CoordinationReport)

          raise HarnessExperimentError, "#{label} report must be a CoordinationReport"
        end

        def validate_reports!
          unless Harness.secure_equal?(training_report.workload.digest, holdout_report.workload.digest) &&
                 Harness.secure_equal?(training_report.baseline_digest, holdout_report.baseline_digest)
            raise HarnessIntegrityError, "composition reports do not share workload and baseline"
          end
          training_topologies = training_report.topologies.map(&:digest).sort
          holdout_topologies = holdout_report.topologies.map(&:digest).sort
          unless training_topologies == holdout_topologies
            raise HarnessIntegrityError, "composition reports do not share the same topologies"
          end
          candidate_count = training_topologies.size - 1
          unless candidate_count.between?(1, context.config.harness.max_experiment_candidates)
            raise HarnessExperimentError, "composition study requires bounded candidates"
          end
          if (training_report.evidence_digests & holdout_report.evidence_digests).any?
            raise HarnessIntegrityError, "composition training and holdout evidence overlap"
          end
          if (training_report.request_digests & holdout_report.request_digests).any?
            raise HarnessIntegrityError, "composition training and holdout requests overlap"
          end
        end

        def normalize_profiles(values)
          list = Array(values)
          unless list.size.between?(1, MAX_PROFILES) && list.all? { |profile| profile.is_a?(AgentProfile) }
            raise HarnessExperimentError, "composition study requires bounded AgentProfiles"
          end
          result = list.sort_by(&:agent).to_h { |profile| [profile.agent, profile] }
          unless result.size == list.size
            raise HarnessExperimentError, "composition profile agents must be unique"
          end

          result.freeze
        end

        def normalize_approved(values)
          approved = Array(values).map do |value|
            Organization.digest!(value, "approved topology digest")
          end.uniq.sort
          expected = topologies.map(&:digest).sort
          unless approved == expected
            raise PolicyDenied, "composition study topology approval set is incomplete or stale"
          end

          approved.freeze
        end

        def authorize_study!(approved_by:, evidence_digest:, authorize:)
          actor = Organization.identifier!(approved_by, "composition approver")
          evidence = Organization.digest!(evidence_digest, "approval evidence digest")
          raise PolicyDenied, "composition study requires an authorizer" unless authorize.respond_to?(:call)

          request = Harness.deep_freeze(
            "action" => "evaluate_composition",
            "study_id" => id,
            "scope" => scope_data,
            "workload_digest" => workload.digest,
            "baseline_digest" => baseline_digest,
            "topology_digests" => approved_topology_digests,
            "training_report_digest" => training_report.digest,
            "holdout_report_digest" => holdout_report.digest,
            "approved_by" => actor,
            "approval_evidence_digest" => evidence
          )
          allowed = authorize.call("evaluate_composition", request, context)
          raise PolicyDenied, "composition study authorization was denied" unless allowed == true

          Harness.deep_freeze(
            "approved_by" => actor,
            "evidence_digest" => evidence,
            "request_digest" => Harness.digest(request),
            "digest" => Harness.digest(
              "approved_by" => actor,
              "evidence_digest" => evidence,
              "request_digest" => Harness.digest(request)
            )
          )
        rescue PolicyDenied
          raise
        rescue StandardError => error
          raise PolicyDenied, "composition study authorization failed (#{error.class.name})"
        end

        def identity
          {
            "id" => id,
            "scope" => scope_data,
            "workload_digest" => workload.digest,
            "baseline_digest" => baseline_digest,
            "topology_digests" => approved_topology_digests,
            "profile_digests" => profiles.transform_values(&:digest),
            "training_report_digest" => training_report.digest,
            "holdout_report_digest" => holdout_report.digest,
            "approval_digest" => approval.fetch("digest")
          }
        end

        def scope_data
          { "tenant_key" => scope.tenant_key || "__global__", "account_id" => scope.account_id }
        end

        def topology(value)
          topologies.find { |item| item.digest == value } ||
            raise(HarnessIntegrityError, "composition topology is missing")
        end

        def candidate_blockers(candidate_digest)
          reasons = []
          training = training_report.comparisons.fetch(candidate_digest)
          holdout = holdout_report.comparisons.fetch(candidate_digest)
          reasons << "training_not_pareto_better" unless training.fetch("relationship") == "pareto_better"
          reasons << "holdout_not_pareto_better" unless holdout.fetch("relationship") == "pareto_better"
          reasons.concat(profile_blockers(topology(candidate_digest)))
          reasons.uniq.sort.freeze
        end

        def profile_blockers(candidate)
          candidate.members.flat_map do |member|
            next [] if member.fetch("role") == "tool"

            profile = profiles[member.fetch("agent")]
            next ["missing_profile:#{member.fetch('agent')}"] unless profile

            reasons = identity_blockers(member, profile)
            member.fetch("capabilities").each do |capability|
              evidence = profile.capabilities[capability]
              unless evidence && evidence.fetch("samples") >= workload.minimum_samples
                reasons << "insufficient_capability_evidence:#{member.fetch('agent')}:#{capability}"
              end
            end
            reasons
          end
        end

        def identity_blockers(member, profile)
          (%w[model_profile] + IDENTITY_DIGESTS).filter_map do |name|
            expected = member[name]
            next unless expected
            next if profile.identity[name] == expected

            "identity_mismatch:#{member.fetch('agent')}:#{name}"
          end
        end

        def pareto_frontier(values)
          values.reject do |candidate_digest|
            values.any? do |other_digest|
              other_digest != candidate_digest && dominates?(
                summary(other_digest), summary(candidate_digest)
              )
            end
          end.sort.freeze
        end

        def dominates?(left, right)
          better_or_equal = left.fetch("success_rate") >= right.fetch("success_rate") &&
                            left.fetch("mean_quality") >= right.fetch("mean_quality") &&
                            left.fetch("mean_cost_usd") <= right.fetch("mean_cost_usd") &&
                            left.fetch("mean_latency_ms") <= right.fetch("mean_latency_ms")
          strict = left.fetch("success_rate") > right.fetch("success_rate") ||
                   left.fetch("mean_quality") > right.fetch("mean_quality") ||
                   left.fetch("mean_cost_usd") < right.fetch("mean_cost_usd") ||
                   left.fetch("mean_latency_ms") < right.fetch("mean_latency_ms")
          better_or_equal && strict
        end

        def summary(candidate_digest) = holdout_report.summaries.fetch(candidate_digest)

        def shortlist_entry(candidate_digest)
          candidate = summary(candidate_digest)
          {
            "topology_digest" => candidate_digest,
            "topology_id" => candidate.fetch("topology_id"),
            "team_size" => candidate.fetch("team_size"),
            "success_rate" => candidate.fetch("success_rate"),
            "mean_quality" => candidate.fetch("mean_quality"),
            "mean_cost_usd" => candidate.fetch("mean_cost_usd"),
            "mean_latency_ms" => candidate.fetch("mean_latency_ms")
          }
        end

        def recommendation_state(frontier)
          return ["retain", nil, "no_holdout_pareto_improvement"] if frontier.empty?
          return ["recommend_review", frontier.first, "unique_holdout_pareto_improvement"] if frontier.one?

          ["needs_choice", nil, "multiple_non_dominated_compositions"]
        end
      end
    end
  end
end
