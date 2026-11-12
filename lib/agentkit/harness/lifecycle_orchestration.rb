# frozen_string_literal: true

module Agentkit
  module Harness
    # Authenticated source data that may justify a replan. The event is data,
    # never authority: it cannot approve or apply a GoalRevision.
    class LifecycleEvent
      TYPES = %w[
        requirement_changed ci_failed ci_recovered review_requested
        review_completed dependency_changed incident_detected manual
      ].freeze
      MAX_SIGNALS_BYTES = 16_384

      attr_reader :id, :type, :source, :summary, :signals, :commit_sha,
                  :observed_at

      def initialize(id:, type:, source:, summary:, signals: {}, commit_sha: nil,
                     observed_at: Time.now.utc)
        @id = required_text(id, "lifecycle event id")
        @type = type.to_s
        raise ArgumentError, "unknown lifecycle event type: #{@type.inspect}" unless TYPES.include?(@type)

        @source = required_text(source, "lifecycle event source")
        @summary = required_text(summary, "lifecycle event summary", maximum: 2_000)
        @signals = DeclarativeData.normalize(
          signals || {}, label: "lifecycle event signals", error_class: HarnessError
        )
        raise ArgumentError, "lifecycle event signals must be an object" unless @signals.is_a?(Hash)
        if JSON.generate(@signals).bytesize > MAX_SIGNALS_BYTES
          raise ArgumentError, "lifecycle event signals exceed #{MAX_SIGNALS_BYTES} bytes"
        end
        @signals = Harness.deep_freeze(@signals)
        @commit_sha = commit_sha && VerificationResult.normalize_commit_sha(commit_sha)
        @observed_at = Harness.time(observed_at)
        raise ArgumentError, "lifecycle event cannot be in the future" if @observed_at > Time.now.utc + 5
        freeze
      end

      def digest = Harness.digest(to_h)

      def to_h
        {
          "id" => id, "type" => type, "source" => source,
          "summary" => summary, "signals" => signals,
          "commit_sha" => commit_sha, "observed_at" => observed_at.iso8601(6)
        }.compact
      end

      private

      def required_text(value, label, maximum: 256)
        text = value.to_s.strip
        unless text.bytesize.between?(1, maximum) && !text.match?(/[[:cntrl:]]/)
          raise ArgumentError, "#{label} must contain 1..#{maximum} safe bytes"
        end

        text.freeze
      end
    end

    # A reviewable suggestion produced from one event and one exact goal. It
    # can create a GoalRevision, but cannot authorize or apply it.
    class ReplanProposal
      attr_reader :id, :planner, :event, :base_goal_digest, :changes, :reason,
                  :next_action, :affected_workstreams, :proposed_at

      def initialize(planner:, event:, base_goal_digest:, changes:, reason:,
                     next_action: nil, affected_workstreams: [], proposed_at: Time.now.utc)
        @id = SecureRandom.uuid.freeze
        @planner = required_text(planner, "planner name")
        raise ArgumentError, "event must be a LifecycleEvent" unless event.is_a?(LifecycleEvent)
        @event = event
        @base_goal_digest = Harness.valid_digest!(base_goal_digest).freeze
        @changes = normalize_changes(changes)
        @reason = required_text(reason, "replan reason", maximum: 2_000)
        @next_action = next_action && required_text(next_action, "next action", maximum: 2_000)
        @affected_workstreams = normalize_names(affected_workstreams)
        @proposed_at = Harness.time(proposed_at)
        freeze
      end

      def digest = digest_without_recursion

      def goal_revision(progress:, proposed_by:)
        raise ArgumentError, "progress must be an Agentkit::Harness::Progress" unless progress.is_a?(Progress)
        unless Harness.secure_equal?(progress.goal.digest, base_goal_digest)
          raise HarnessIntegrityError, "replan proposal is stale for the current goal"
        end

        GoalRevision.propose(
          progress: progress, changes: changes,
          reason: reason, proposed_by: proposed_by
        )
      end

      def to_h
        Harness.deep_freeze(
          "id" => id, "proposal_digest" => digest_without_recursion,
          "planner" => planner, "event_digest" => event.digest,
          "base_goal_digest" => base_goal_digest, "changes" => changes,
          "reason" => reason, "next_action" => next_action,
          "affected_workstreams" => affected_workstreams,
          "proposed_at" => proposed_at.iso8601(6), "authorizes" => false
        )
      end

      private

      def digest_without_recursion
        Harness.digest(
          "id" => id, "planner" => planner, "event_digest" => event.digest,
          "base_goal_digest" => base_goal_digest, "changes" => changes,
          "reason" => reason, "next_action" => next_action,
          "affected_workstreams" => affected_workstreams,
          "proposed_at" => proposed_at.iso8601(6)
        )
      end

      def normalize_changes(value)
        data = DeclarativeData.normalize(
          value || {}, label: "replan changes", error_class: HarnessError
        )
        raise ArgumentError, "replan changes must be a nonempty object" unless data.is_a?(Hash) && data.any?
        unknown = data.keys - GoalRevision::CHANGE_KEYS
        raise ArgumentError, "unknown replan fields: #{unknown.join(', ')}" if unknown.any?
        raise ArgumentError, "replan changes exceed 64 KiB" if JSON.generate(data).bytesize > 65_536

        Harness.deep_freeze(data)
      end

      def normalize_names(values)
        names = Array(values).map { |value| required_text(value, "workstream") }.uniq
        raise ArgumentError, "replan proposal allows at most 32 workstreams" if names.size > 32

        names.freeze
      end

      def required_text(value, label, maximum: 256)
        text = value.to_s.strip
        unless text.bytesize.between?(1, maximum) && !text.match?(/[[:cntrl:]]/)
          raise ArgumentError, "#{label} must contain 1..#{maximum} safe bytes"
        end

        text.freeze
      end
    end

    # Deterministic admission wrapper around a host planner. The callback may
    # be a rules engine or an LLM-backed service, but its output is declarative
    # and remains a proposal requiring the normal GoalRevision approval rail.
    class LifecycleReplanner
      def initialize(name:, planner:, authorize:)
        @name = required_text(name, "replanner name")
        @planner = planner
        @authorize = authorize
        unless @planner.respond_to?(:call) && @authorize.respond_to?(:call)
          raise ArgumentError, "replanner requires planner and authorizer callbacks"
        end
      end

      def propose(progress:, event:, context: nil)
        raise ArgumentError, "progress must be an Agentkit::Harness::Progress" unless progress.is_a?(Progress)
        raise ArgumentError, "event must be an Agentkit::Harness::LifecycleEvent" unless event.is_a?(LifecycleEvent)
        raise HarnessError, "completed or failed progress cannot be replanned" if %w[completed failed].include?(progress.status)

        ctx = context || Context.resolve
        request = request_for(progress, event)
        allowed = @authorize.call("propose", request, ctx)
        raise PolicyDenied, "lifecycle replanning denied" unless allowed == true

        raw = begin
          @planner.call(request, ctx)
        rescue StandardError => error
          raise HarnessError, "lifecycle replanner unavailable (#{error.class.name})"
        end
        data = DeclarativeData.normalize(
          raw || {}, label: "replanner response", error_class: HarnessError
        )
        raise HarnessError, "replanner response must be an object" unless data.is_a?(Hash)
        allowed_keys = %w[changes reason next_action affected_workstreams]
        unknown = data.keys - allowed_keys
        raise HarnessError, "replanner returned unknown fields: #{unknown.join(', ')}" if unknown.any?

        proposal = ReplanProposal.new(
          planner: @name, event: event, base_goal_digest: progress.goal.digest,
          changes: data.fetch("changes"), reason: data.fetch("reason"),
          next_action: data["next_action"],
          affected_workstreams: data["affected_workstreams"] || []
        )
        Agentkit.with_context(ctx) do
          Audit.record(
            event_type: "harness.replan.proposed", agent_name: @name,
            status: "proposed", payload: proposal.to_h, context: ctx
          )
          Telemetry.emit(
            "harness.replan.proposed",
            dims: { goal_id: progress.goal.id, event_type: event.type, planner: @name },
            measures: { changed_fields: proposal.changes.size,
                        workstreams: proposal.affected_workstreams.size }
          )
        end
        proposal
      rescue KeyError => error
        raise HarnessError, "replanner response is incomplete: #{error.message}"
      end

      private

      def request_for(progress, event)
        Harness.deep_freeze(
          "goal" => progress.goal.to_h,
          "goal_digest" => progress.goal.digest,
          "status" => progress.status,
          "step_count" => progress.step_count,
          "next_action" => progress.next_action,
          "evidence" => progress.evidence.transform_values do |item|
            { "verdict" => item.verdict, "digest" => item.digest, "source" => item.source }
          end,
          "outputs" => progress.outputs.transform_values do |item|
            { "reference" => item["reference"], "digest" => item["digest"] }
          end,
          "event" => event.to_h,
          "event_is_untrusted_data" => true
        )
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise ArgumentError, "#{label} is required" if text.empty?

        text.freeze
      end
    end

    # Read-only projection of an in-flight goal into work items and exact
    # blockers. It does not invoke a model, persist data or mutate Progress.
    class LifecycleProjection
      def self.build(progress:, release_candidate: nil, events: [], proposals: [], revisions: [])
        new(
          progress: progress, release_candidate: release_candidate,
          events: events, proposals: proposals, revisions: revisions
        ).to_h
      end

      def initialize(progress:, release_candidate:, events:, proposals:, revisions:)
        raise ArgumentError, "progress must be an Agentkit::Harness::Progress" unless progress.is_a?(Progress)
        if release_candidate && !release_candidate.is_a?(ReleaseCandidateReceipt)
          raise ArgumentError, "release_candidate must be a ReleaseCandidateReceipt"
        end
        unless Array(events).all? { |item| item.is_a?(LifecycleEvent) }
          raise ArgumentError, "events must contain LifecycleEvent values"
        end
        unless Array(proposals).all? { |item| item.is_a?(ReplanProposal) }
          raise ArgumentError, "proposals must contain ReplanProposal values"
        end
        unless Array(revisions).all? { |item| item.is_a?(RevisionResult) }
          raise ArgumentError, "revisions must contain RevisionResult values"
        end

        @progress = progress
        @release_candidate = release_candidate
        @events = Array(events)
        @proposals = Array(proposals)
        @revisions = Array(revisions)
      end

      def to_h
        requirements = requirement_items
        artifacts = artifact_items
        gates = @release_candidate ? @release_candidate["verification_gates"] : []
        blockers = blocker_items(requirements, artifacts, gates)
        value = {
          "schema" => "agentkit.lifecycle_projection.v1",
          "goal_id" => @progress.goal.id,
          "goal_digest" => @progress.goal.digest,
          "status" => projection_status(blockers),
          "phases" => phases(requirements, artifacts, gates),
          "work_items" => requirements + artifacts + gate_items(gates),
          "blockers" => blockers,
          "events" => event_summary,
          "open_replans" => @proposals.map do |proposal|
            { "id" => proposal.id, "digest" => proposal.digest,
              "event_digest" => proposal.event.digest,
              "affected_workstreams" => proposal.affected_workstreams }
          end,
          "invalidated" => {
            "evidence" => @revisions.sum { |item| item.invalidated_evidence.size },
            "outputs" => @revisions.sum { |item| item.invalidated_outputs.size },
            "approvals" => @revisions.sum { |item| item.invalidated_approvals.size }
          },
          "generated_at" => Time.now.utc.iso8601(6)
        }
        value["projection_digest"] = Harness.digest(value)
        Harness.deep_freeze(value)
      end

      private

      def requirement_items
        (@progress.goal.criteria + @progress.goal.constraints).map do |requirement|
          evidence = @progress.evidence[requirement.id]
          {
            "id" => "requirement:#{requirement.id}", "kind" => "requirement",
            "required" => requirement.required?, "status" => evidence&.verdict || "missing",
            "evidence_digest" => evidence&.digest
          }.compact
        end
      end

      def artifact_items
        @progress.goal.required_outputs.map do |name|
          output = @progress.outputs[name]
          {
            "id" => "output:#{name}", "kind" => "output", "required" => true,
            "status" => output ? "recorded" : "missing", "digest" => output&.fetch("digest")
          }.compact
        end
      end

      def gate_items(gates)
        gates.map do |gate|
          {
            "id" => "gate:#{gate.fetch('id')}", "kind" => "verification_gate",
            "required" => gate.fetch("required"), "status" => gate.fetch("status"),
            "evidence_digest" => gate["evidence_digest"]
          }.compact
        end
      end

      def blocker_items(requirements, artifacts, gates)
        blocked = []
        requirements.each do |item|
          next unless item["required"] && item["status"] != "verified"
          blocked << { "code" => "requirement_#{item['status']}", "item" => item["id"] }
        end
        artifacts.each do |item|
          blocked << { "code" => "output_missing", "item" => item["id"] } if item["status"] == "missing"
        end
        missing_approvals.each do |name|
          blocked << { "code" => "approval_missing", "item" => "approval:#{name}" }
        end
        gates.each do |gate|
          next unless gate["required"] && gate["status"] != "passed"
          blocked << { "code" => "gate_#{gate['status']}", "item" => "gate:#{gate['id']}" }
        end
        blocked
      end

      def missing_approvals
        @progress.goal.required_approvals.reject do |required|
          @progress.approvals.any? do |name, value|
            matches = name == required ||
                      (required.end_with?("*") && name.start_with?(required.delete_suffix("*")))
            matches && value["status"] == "approved"
          end
        end
      end

      def phases(requirements, artifacts, gates)
        {
          "plan" => @proposals.empty? ? "stable" : "replan_proposed",
          "build" => artifacts.all? { |item| item["status"] == "recorded" } ? "complete" : "in_progress",
          "verify" => requirements.select { |item| item["required"] }
                                  .all? { |item| item["status"] == "verified" } ? "complete" : "blocked",
          "release" => if @release_candidate.nil?
                         "not_configured"
                       elsif @release_candidate.ready?
                         "ready"
                       elsif gates.any? { |gate| gate["status"] == "stale" }
                         "stale"
                       else
                         "blocked"
                       end
        }
      end

      def event_summary
        @events.group_by(&:type).sort.to_h do |type, values|
          [type, { "count" => values.size, "latest_at" => values.map(&:observed_at).max.iso8601(6) }]
        end
      end

      def projection_status(blockers)
        return "failed" if @progress.status == "failed"
        return "ready" if blockers.empty? && @release_candidate&.ready?
        return "replanning" if @proposals.any?

        blockers.empty? ? "in_progress" : "blocked"
      end
    end
  end
end
