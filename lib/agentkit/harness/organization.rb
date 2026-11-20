# frozen_string_literal: true

module Agentkit
  module Harness
    # Evidence-bound organizational telemetry and coordination profiles.
    # It measures approved compositions; it never creates agents, grants tools,
    # promotes a topology or invokes a model by itself.
    module Organization
      MAX_MEMBERS = 16
      MAX_EDGES = 64
      MAX_CAPABILITIES = 64
      MAX_OBSERVATIONS = 2_000
      PATTERNS = %w[single pipeline coordinator parallel verifier custom].freeze
      ROLES = %w[coordinator planner domain research verifier human tool unknown].freeze
      EDGE_KINDS = %w[handoff parallel verification supervision].freeze
      IDENTITY_DIGESTS = %w[toolset_digest skills_digest policy_digest].freeze

      module_function

      def identifier!(value, label)
        ArchitectureEvaluation.name!(value.to_s)
      rescue HarnessExperimentError
        raise HarnessExperimentError, "#{label} must be a bounded identifier"
      end

      def digest!(value, label)
        Harness.valid_digest!(value.to_s)
      rescue ArgumentError
        raise HarnessExperimentError, "#{label} must be a sha256 digest"
      end

      def number!(value, label, minimum: 0.0, maximum: nil)
        number = Float(value)
        invalid = !number.finite? || number < minimum || (maximum && number > maximum)
        raise HarnessExperimentError, "#{label} is outside its allowed range" if invalid

        number
      rescue ArgumentError, TypeError
        raise HarnessExperimentError, "#{label} must be numeric"
      end

      def integer!(value, label, minimum: 0, maximum: nil)
        number = Integer(value)
        invalid = number < minimum || (maximum && number > maximum)
        raise HarnessExperimentError, "#{label} is outside its allowed range" if invalid

        number
      rescue ArgumentError, TypeError
        raise HarnessExperimentError, "#{label} must be an integer"
      end

      def boolean!(value, label)
        raise HarnessExperimentError, "#{label} must be boolean" unless [true, false].include?(value)

        value
      end

      def json_hash!(value, label)
        normalized = DeclarativeData.normalize(value, label: label, error_class: HarnessExperimentError)
        raise HarnessExperimentError, "#{label} must be an object" unless normalized.is_a?(Hash)

        Harness.deep_freeze(normalized)
      end

      def role!(value)
        role = value.to_s
        raise HarnessExperimentError, "unknown organization role" unless ROLES.include?(role)

        role
      end

      # Adds an allowlisted organizational envelope to the current context and
      # aggregates nested llm.call telemetry by the fresh child run id.
      def instrument(request_id:, organization_id:, topology:, agent:, role:, capability:,
                     handoff_from: nil, model_profile: nil, toolset_digest: nil,
                     skills_digest: nil, policy_digest: nil, independent_context: false,
                     permission_boundary: false, context: Context.resolve)
        raise ArgumentError, "instrument requires a block" unless block_given?

        topology_data = topology.is_a?(Topology) ? topology : nil
        dimensions = {
          organization_id: identifier!(organization_id, "organization id"),
          request_digest: Harness.digest(request_id.to_s),
          topology_digest: topology_data ? topology_data.digest : digest!(topology, "topology digest"),
          topology_pattern: topology_data&.pattern,
          agent: identifier!(agent, "agent"), role: role!(role),
          capability: identifier!(capability, "capability"),
          handoff_from: handoff_from && identifier!(handoff_from, "handoff source"),
          model_profile: model_profile && identifier!(model_profile, "model profile"),
          toolset_digest: toolset_digest && digest!(toolset_digest, "toolset digest"),
          skills_digest: skills_digest && digest!(skills_digest, "skills digest"),
          policy_digest: policy_digest && digest!(policy_digest, "policy digest"),
          independent_context: boolean!(independent_context, "independent context"),
          permission_boundary: boolean!(permission_boundary, "permission boundary")
        }.compact.freeze
        child = context.derive(metadata: { organization: dimensions })
        nested = []
        subscriber = Telemetry.subscribe do |event|
          nested << event if event.run_id == child.run_id && event.name == "llm.call"
        end
        measures = {}
        status = "ok"
        error = nil
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Agentkit.with_context(child) { yield(measures, child) }
      rescue StandardError => caught
        status = "error"
        error = caught
        raise
      ensure
        Telemetry.unsubscribe(subscriber) if subscriber
        if child
          duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
          begin
            normalized = normalize_call_measures(measures || {})
          rescue StandardError => measurement_error
            normalized = {}
            status = "measurement_error" if status == "ok"
            error ||= measurement_error
            Agentkit.logger&.warn(
              "[AgentKit::Organization] #{measurement_error.class}: invalid organizational measurements"
            )
          end
          Agentkit.with_context(child) do
            Telemetry.emit("organization.call",
              dims: dimensions.merge(status: status, error_class: error&.class&.name),
              measures: normalized.merge(aggregate_llm(nested || [])).merge(duration_ms: duration))
          end
        end
      end

      def normalize_call_measures(value)
        data = json_hash!(value, "organization call measures")
        allowed = {}
        %w[context_bytes retries verifier_rejections duplicate_work handoffs failed_handoffs].each do |key|
          allowed[key.to_sym] = integer!(data[key], key, minimum: 0) if data.key?(key)
        end
        %w[quality context_retention human_minutes].each do |key|
          next unless data.key?(key)

          maximum = %w[quality context_retention].include?(key) ? 1.0 : nil
          allowed[key.to_sym] = number!(data[key], key, maximum: maximum)
        end
        allowed[:success] = boolean!(data["success"], "success") if data.key?("success")
        allowed
      end
      private_class_method :normalize_call_measures

      def aggregate_llm(events)
        {
          input_tokens: events.sum { |event| event.measures[:input_tokens].to_i },
          output_tokens: events.sum { |event| event.measures[:output_tokens].to_i },
          cost_usd: events.sum { |event| event.measures[:cost_usd].to_f }.round(8),
          llm_retries: events.sum { |event| event.measures[:retries].to_i },
          llm_calls: events.size
        }
      end
      private_class_method :aggregate_llm

      class Topology
        attr_reader :id, :pattern, :members, :edges, :metadata

        def initialize(id:, pattern:, members:, edges: [], metadata: {})
          @id = Organization.identifier!(id, "topology id").freeze
          @pattern = pattern.to_s.freeze
          raise HarnessExperimentError, "unknown organization topology pattern" unless PATTERNS.include?(@pattern)

          @members = normalize_members(members)
          @edges = normalize_edges(edges)
          @metadata = Organization.json_hash!(metadata, "topology metadata")
          freeze
        end

        def size = members.size
        def digest = Harness.digest(to_h)

        def to_h
          Harness.deep_freeze(
            "schema_version" => 1, "id" => id, "pattern" => pattern,
            "members" => members, "edges" => edges, "metadata" => metadata
          )
        end

        private

        def normalize_members(values)
          unless values.is_a?(Array) && values.size.between?(1, MAX_MEMBERS)
            raise HarnessExperimentError, "topology requires 1..#{MAX_MEMBERS} members"
          end
          normalized = values.map do |raw|
            data = Organization.json_hash!(raw, "topology member")
            agent = Organization.identifier!(data.fetch("agent"), "member agent")
            role = Organization.role!(data.fetch("role", "unknown"))
            capabilities = Array(data.fetch("capabilities", [])).map do |name|
              Organization.identifier!(name, "member capability")
            end.uniq.sort
            raise HarnessExperimentError, "member capabilities exceed bound" if capabilities.size > MAX_CAPABILITIES

            flags = %w[independent_context permission_boundary].to_h do |name|
              [name, Organization.boolean!(data.fetch(name, false), name)]
            end
            if role == "verifier" && flags.values.none?
              raise HarnessExperimentError, "verifier members require an isolation boundary"
            end
            identity = IDENTITY_DIGESTS.to_h do |name|
              value = data[name]
              [name, value && Organization.digest!(value, name)]
            end.compact
            {
              "agent" => agent, "role" => role, "capabilities" => capabilities,
              "model_profile" => data["model_profile"] &&
                Organization.identifier!(data["model_profile"], "model profile")
            }.merge(flags).merge(identity).compact
          rescue KeyError => error
            raise HarnessExperimentError, "topology member is missing #{error.key}"
          end
          names = normalized.map { |member| member.fetch("agent") }
          raise HarnessExperimentError, "topology member agents must be unique" unless names.uniq.size == names.size

          Harness.deep_freeze(normalized.sort_by { |member| member.fetch("agent") })
        end

        def normalize_edges(values)
          unless values.is_a?(Array) && values.size <= MAX_EDGES
            raise HarnessExperimentError, "topology edges exceed bound"
          end
          names = members.map { |member| member.fetch("agent") }
          normalized = values.map do |raw|
            data = Organization.json_hash!(raw, "topology edge")
            source = Organization.identifier!(data.fetch("from"), "edge source")
            target = Organization.identifier!(data.fetch("to"), "edge target")
            kind = data.fetch("kind", "handoff").to_s
            unless names.include?(source) && names.include?(target) && source != target
              raise HarnessExperimentError, "topology edge references invalid members"
            end
            raise HarnessExperimentError, "unknown topology edge kind" unless EDGE_KINDS.include?(kind)

            { "from" => source, "to" => target, "kind" => kind }
          rescue KeyError => error
            raise HarnessExperimentError, "topology edge is missing #{error.key}"
          end
          raise HarnessExperimentError, "topology edges must be unique" unless normalized.uniq.size == normalized.size

          Harness.deep_freeze(normalized.sort_by { |edge| [edge["from"], edge["to"], edge["kind"]] })
        end
      end

      class WorkloadContract
        attr_reader :id, :capabilities, :required_checks, :max_agents,
                    :max_cost_usd, :max_latency_ms, :max_human_minutes,
                    :minimum_samples, :metadata

        def initialize(id:, capabilities:, required_checks: [], max_agents: MAX_MEMBERS,
                       max_cost_usd:, max_latency_ms:, max_human_minutes: 0,
                       minimum_samples: 2, metadata: {})
          @id = Organization.identifier!(id, "workload id").freeze
          @capabilities = identifiers(capabilities, "workload capability")
          raise HarnessExperimentError, "workload requires capabilities" if @capabilities.empty?
          @required_checks = identifiers(required_checks, "workload check")
          @max_agents = Organization.integer!(max_agents, "max agents", minimum: 1, maximum: MAX_MEMBERS)
          @max_cost_usd = Organization.number!(max_cost_usd, "max cost", minimum: 0.0)
          @max_latency_ms = Organization.number!(max_latency_ms, "max latency", minimum: 0.0)
          @max_human_minutes = Organization.number!(max_human_minutes, "max human minutes", minimum: 0.0)
          @minimum_samples = Organization.integer!(minimum_samples, "minimum samples", minimum: 2, maximum: 100)
          @metadata = Organization.json_hash!(metadata, "workload metadata")
          freeze
        end

        def digest = Harness.digest(to_h)

        def within_bounds?(team_size:, cost_usd:, latency_ms:, human_minutes: 0)
          team_size <= max_agents && cost_usd <= max_cost_usd &&
            latency_ms <= max_latency_ms && human_minutes <= max_human_minutes
        end

        def to_h
          Harness.deep_freeze(
            "schema_version" => 1, "id" => id, "capabilities" => capabilities,
            "required_checks" => required_checks, "bounds" => {
              "max_agents" => max_agents, "max_cost_usd" => max_cost_usd,
              "max_latency_ms" => max_latency_ms, "max_human_minutes" => max_human_minutes,
              "minimum_samples" => minimum_samples
            }, "metadata" => metadata
          )
        end

        private

        def identifiers(values, label)
          list = Array(values).map { |value| Organization.identifier!(value, label) }.uniq.sort
          raise HarnessExperimentError, "#{label} values exceed bound" if list.size > MAX_CAPABILITIES

          list.freeze
        end
      end

      # A profile is calculated from evaluated tasks and redacted evidence
      # digests. It never accepts free-form claims made by the profiled agent.
      class AgentProfile
        attr_reader :agent, :identity, :capabilities, :coordination, :evidence_digests

        def self.build(agent:, identity:, observations:, coordination_observations: [])
          new(agent: agent, identity: identity, observations: observations,
              coordination_observations: coordination_observations)
        end

        def initialize(agent:, identity:, observations:, coordination_observations: [])
          @agent = Organization.identifier!(agent, "profile agent").freeze
          @identity = normalize_identity(identity)
          rows = normalize_observations(observations)
          @capabilities = summarize_capabilities(rows)
          coordination_rows = normalize_coordination(coordination_observations)
          @coordination = summarize_coordination(coordination_rows)
          @evidence_digests = (rows + coordination_rows).map do |row|
            row.fetch("evidence_digest")
          end.uniq.sort.freeze
          freeze
        end

        def digest = Harness.digest(to_h)

        def to_h
          Harness.deep_freeze(
            "schema_version" => 1, "agent" => agent, "identity" => identity,
            "capabilities" => capabilities, "coordination" => coordination,
            "evidence_digests" => evidence_digests
          )
        end

        private

        def normalize_identity(value)
          data = Organization.json_hash!(value, "agent identity")
          result = {}
          if data["model_profile"]
            result["model_profile"] = Organization.identifier!(data["model_profile"], "model profile")
          end
          IDENTITY_DIGESTS.each do |name|
            result[name] = Organization.digest!(data[name], name) if data[name]
          end
          if result.empty?
            raise HarnessExperimentError, "agent identity requires model profile or component digests"
          end

          Harness.deep_freeze(result)
        end

        def normalize_observations(values)
          unless values.is_a?(Array) && values.size.between?(1, MAX_OBSERVATIONS)
            raise HarnessExperimentError, "agent profile requires bounded observations"
          end
          Harness.deep_freeze(values.map do |raw|
            data = Organization.json_hash!(raw, "capability observation")
            {
              "capability" => Organization.identifier!(data.fetch("capability"), "capability"),
              "task_digest" => Organization.digest!(data.fetch("task_digest"), "task digest"),
              "evidence_digest" => Organization.digest!(data.fetch("evidence_digest"), "evidence digest"),
              "success" => Organization.boolean!(data.fetch("success"), "success"),
              "quality" => Organization.number!(data.fetch("quality"), "quality", maximum: 1.0),
              "cost_usd" => Organization.number!(data.fetch("cost_usd"), "cost"),
              "latency_ms" => Organization.number!(data.fetch("latency_ms"), "latency")
            }
          rescue KeyError => error
            raise HarnessExperimentError, "capability observation is missing #{error.key}"
          end)
        end

        def normalize_coordination(values)
          unless values.is_a?(Array) && values.size <= MAX_OBSERVATIONS
            raise HarnessExperimentError, "coordination observations exceed bound"
          end
          Harness.deep_freeze(values.map do |raw|
            data = Organization.json_hash!(raw, "coordination observation")
            {
              "evidence_digest" => Organization.digest!(data.fetch("evidence_digest"), "evidence digest"),
              "handoff_success" => Organization.boolean!(data.fetch("handoff_success"), "handoff success"),
              "context_retention" => Organization.number!(data.fetch("context_retention"),
                "context retention", maximum: 1.0),
              "conflict" => Organization.boolean!(data.fetch("conflict", false), "conflict"),
              "retries" => Organization.integer!(data.fetch("retries", 0), "retries", minimum: 0)
            }
          rescue KeyError => error
            raise HarnessExperimentError, "coordination observation is missing #{error.key}"
          end)
        end

        def summarize_capabilities(rows)
          Harness.deep_freeze(rows.group_by { |row| row.fetch("capability") }.sort.to_h do |name, group|
            [name, {
              "samples" => group.size,
              "success_rate" => ratio(group.count { |row| row.fetch("success") }, group.size),
              "mean_quality" => mean(group, "quality"),
              "mean_cost_usd" => mean(group, "cost_usd"),
              "mean_latency_ms" => mean(group, "latency_ms")
            }]
          end)
        end

        def summarize_coordination(rows)
          return Harness.deep_freeze("samples" => 0, "complete" => false) if rows.empty?

          Harness.deep_freeze(
            "samples" => rows.size, "complete" => true,
            "handoff_success_rate" => ratio(rows.count { |row| row.fetch("handoff_success") }, rows.size),
            "mean_context_retention" => mean(rows, "context_retention"),
            "conflict_rate" => ratio(rows.count { |row| row.fetch("conflict") }, rows.size),
            "mean_retries" => mean(rows, "retries")
          )
        end

        def mean(rows, key) = (rows.sum { |row| row.fetch(key).to_f } / rows.size).round(6)
        def ratio(count, total) = (count.to_f / total).round(6)
      end

      # Compares approved topologies against a mandatory single-agent baseline.
      # The result exposes a Pareto relationship instead of inventing a weighted
      # utility score that could hide safety, cost or latency regressions.
      class CoordinationReport
        attr_reader :workload, :topologies, :baseline_digest, :summaries,
                    :comparisons, :evidence_digests, :request_digests,
                    :request_set_digest

        def self.build(workload:, topologies:, baseline:, observations:)
          new(workload: workload, topologies: topologies, baseline: baseline,
              observations: observations)
        end

        def initialize(workload:, topologies:, baseline:, observations:)
          unless workload.is_a?(WorkloadContract)
            raise HarnessExperimentError, "workload must be a WorkloadContract"
          end
          @workload = workload
          candidates = Array(topologies)
          unless candidates.size.between?(1, 32) && candidates.all? { |item| item.is_a?(Topology) }
            raise HarnessExperimentError, "coordination report requires bounded topologies"
          end
          digests = candidates.map(&:digest)
          unless digests.uniq.size == digests.size
            raise HarnessExperimentError, "coordination topologies must be unique"
          end
          @topologies = candidates.freeze
          @baseline_digest = baseline.is_a?(Topology) ? baseline.digest :
            Organization.digest!(baseline, "baseline digest")
          baseline_topology = candidates.find { |item| item.digest == @baseline_digest }
          raise HarnessExperimentError, "baseline topology is not in the report" unless baseline_topology
          unless baseline_topology.size == 1
            raise HarnessExperimentError, "baseline topology must contain one member"
          end

          rows = normalize_observations(observations, digests)
          @request_counts = Harness.deep_freeze(rows.group_by do |row|
            row.fetch("topology_digest")
          end.transform_values do |group|
            group.map { |row| row.fetch("request_digest") }.tally.sort.to_h
          end)
          @request_digests = @request_counts.values.flat_map(&:keys).uniq.sort.freeze
          @request_set_digest = Harness.digest(@request_counts).freeze
          @evidence_digests = rows.map { |row| row.fetch("evidence_digest") }.uniq.sort.freeze
          @summaries = summarize(rows)
          @comparisons = compare
          size = JSON.generate(to_h).bytesize
          if size > Context.resolve.config.harness.max_checkpoint_bytes
            raise HarnessPersistenceError, "coordination report exceeds checkpoint byte limit"
          end
          freeze
        end

        def digest = Harness.digest(to_h)

        def to_h
          Harness.deep_freeze(
            "schema_version" => 1, "kind" => "organization_coordination_report",
            "workload" => workload.to_h, "topologies" => topologies.map(&:to_h),
            "baseline_digest" => baseline_digest, "summaries" => summaries,
            "comparisons" => comparisons, "request_set_digest" => request_set_digest,
            "evidence_digests" => evidence_digests
          )
        end

        private

        def normalize_observations(values, topology_digests)
          unless values.is_a?(Array) && values.size.between?(1, MAX_OBSERVATIONS)
            raise HarnessExperimentError, "coordination report requires bounded observations"
          end
          Harness.deep_freeze(values.map do |raw|
            data = Organization.json_hash!(raw, "coordination run")
            topology_digest = Organization.digest!(data.fetch("topology_digest"), "topology digest")
            unless topology_digests.include?(topology_digest)
              raise HarnessExperimentError, "coordination run references an unknown topology"
            end
            topology = topologies.find { |item| item.digest == topology_digest }
            checks = Organization.json_hash!(data.fetch("checks", {}), "coordination checks")
            checks.each do |name, verdict|
              Organization.identifier!(name, "check")
              unless [true, false].include?(verdict)
                raise HarnessExperimentError, "coordination checks require boolean verdicts"
              end
            end
            missing = workload.required_checks - checks.keys
            raise HarnessExperimentError, "coordination run is missing required checks" if missing.any?

            cost = Organization.number!(data.fetch("cost_usd"), "cost")
            latency = Organization.number!(data.fetch("latency_ms"), "latency")
            human = Organization.number!(data.fetch("human_minutes", 0), "human minutes")
            handoffs = Organization.integer!(data.fetch("handoffs", 0), "handoffs", minimum: 0)
            failed = Organization.integer!(data.fetch("failed_handoffs", 0), "failed handoffs", minimum: 0)
            raise HarnessExperimentError, "failed handoffs exceed handoffs" if failed > handoffs

            {
              "topology_digest" => topology_digest,
              "request_digest" => Organization.digest!(data.fetch("request_digest"), "request digest"),
              "evidence_digest" => Organization.digest!(data.fetch("evidence_digest"), "evidence digest"),
              "success" => Organization.boolean!(data.fetch("success"), "success"),
              "quality" => Organization.number!(data.fetch("quality"), "quality", maximum: 1.0),
              "cost_usd" => cost, "latency_ms" => latency, "human_minutes" => human,
              "handoffs" => handoffs, "failed_handoffs" => failed,
              "context_retention" => Organization.number!(
                data.fetch("context_retention", handoffs.zero? ? 1 : 0),
                "context retention", maximum: 1.0
              ),
              "duplicate_work" => Organization.integer!(data.fetch("duplicate_work", 0),
                "duplicate work", minimum: 0),
              "verifier_rejections" => Organization.integer!(data.fetch("verifier_rejections", 0),
                "verifier rejections", minimum: 0),
              "checks" => checks,
              "within_bounds" => workload.within_bounds?(
                team_size: topology.size, cost_usd: cost,
                latency_ms: latency, human_minutes: human
              )
            }
          rescue KeyError => error
            raise HarnessExperimentError, "coordination run is missing #{error.key}"
          end)
        end

        def summarize(rows)
          Harness.deep_freeze(topologies.sort_by(&:digest).to_h do |topology|
            group = rows.select { |row| row.fetch("topology_digest") == topology.digest }
            [topology.digest, summary(topology, group)]
          end)
        end

        def summary(topology, rows)
          if rows.empty?
            return { "topology_id" => topology.id, "team_size" => topology.size,
                     "samples" => 0, "complete" => false, "within_bounds_rate" => 0.0 }
          end

          handoffs = rows.sum { |row| row.fetch("handoffs") }
          failed = rows.sum { |row| row.fetch("failed_handoffs") }
          checks = workload.required_checks.to_h do |name|
            [name, ratio(rows.count { |row| row.fetch("checks").fetch(name) }, rows.size)]
          end
          declared_capabilities = topology.members.flat_map do |member|
            member.fetch("capabilities")
          end.uniq.sort
          missing_capabilities = workload.capabilities - declared_capabilities
          {
            "topology_id" => topology.id, "team_size" => topology.size,
            "samples" => rows.size, "complete" => rows.size >= workload.minimum_samples,
            "capability_coverage" => ratio(
              workload.capabilities.size - missing_capabilities.size,
              workload.capabilities.size
            ),
            "missing_capabilities" => missing_capabilities,
            "success_rate" => ratio(rows.count { |row| row.fetch("success") }, rows.size),
            "mean_quality" => mean(rows, "quality"),
            "mean_cost_usd" => mean(rows, "cost_usd"),
            "mean_latency_ms" => mean(rows, "latency_ms"),
            "mean_human_minutes" => mean(rows, "human_minutes"),
            "within_bounds_rate" => ratio(rows.count { |row| row.fetch("within_bounds") }, rows.size),
            "handoff_failure_rate" => handoffs.zero? ? 0.0 : ratio(failed, handoffs),
            "mean_context_retention" => mean(rows, "context_retention"),
            "duplicate_work" => rows.sum { |row| row.fetch("duplicate_work") },
            "verifier_rejections" => rows.sum { |row| row.fetch("verifier_rejections") },
            "required_check_pass_rates" => checks
          }
        end

        def compare
          baseline = summaries.fetch(baseline_digest)
          Harness.deep_freeze(summaries.reject { |digest, _| digest == baseline_digest }.to_h do |digest, candidate|
            [digest, comparison(baseline, candidate, digest)]
          end)
        end

        def comparison(baseline, candidate, candidate_digest)
          complete = baseline["complete"] && candidate["complete"]
          matched_requests = @request_counts.fetch(candidate_digest, {}) ==
                             @request_counts.fetch(baseline_digest, {})
          required_checks_pass = [baseline, candidate].all? do |summary|
            summary.fetch("required_check_pass_rates", {}).values.all? { |rate| rate == 1.0 }
          end
          blocked = !complete || !matched_requests || !required_checks_pass ||
                    baseline["within_bounds_rate"] < 1.0 || candidate["within_bounds_rate"] < 1.0 ||
                    baseline["capability_coverage"] < 1.0 || candidate["capability_coverage"] < 1.0
          dimensions = {
            "matched_requests" => matched_requests,
            "success_rate_delta" => delta(candidate, baseline, "success_rate"),
            "quality_delta" => delta(candidate, baseline, "mean_quality"),
            "cost_ratio" => ratio_value(candidate["mean_cost_usd"], baseline["mean_cost_usd"]),
            "latency_ratio" => ratio_value(candidate["mean_latency_ms"], baseline["mean_latency_ms"]),
            "handoff_failure_rate" => candidate["handoff_failure_rate"],
            "context_retention_delta" => delta(candidate, baseline, "mean_context_retention")
          }
          relationship = if blocked
                           "blocked"
                         elsif dominates?(candidate, baseline)
                           "pareto_better"
                         elsif dominates?(baseline, candidate)
                           "pareto_worse"
                         else
                           "tradeoff"
                         end
          { "relationship" => relationship, "complete" => complete,
            "coordination_return" => dimensions }
        end

        def dominates?(left, right)
          better_or_equal = left["success_rate"] >= right["success_rate"] &&
                            left["mean_quality"] >= right["mean_quality"] &&
                            left["mean_cost_usd"] <= right["mean_cost_usd"] &&
                            left["mean_latency_ms"] <= right["mean_latency_ms"]
          strict = left["success_rate"] > right["success_rate"] ||
                   left["mean_quality"] > right["mean_quality"] ||
                   left["mean_cost_usd"] < right["mean_cost_usd"] ||
                   left["mean_latency_ms"] < right["mean_latency_ms"]
          better_or_equal && strict
        end

        def delta(left, right, key)
          return nil unless left.key?(key) && right.key?(key)

          (left.fetch(key) - right.fetch(key)).round(6)
        end

        def ratio_value(numerator, denominator)
          return nil unless numerator && denominator && denominator.positive?

          (numerator / denominator).round(6)
        end

        def mean(rows, key) = (rows.sum { |row| row.fetch(key).to_f } / rows.size).round(6)
        def ratio(count, total) = (count.to_f / total).round(6)
      end

      # Reconstructs bounded, redacted delegation traces from kernel telemetry.
      # Request bodies and raw request identifiers never enter the report.
      class TraceSet
        attr_reader :traces, :agents, :scope, :incomplete

        def self.from_telemetry(since: nil, context: Context.resolve)
          new(events: Telemetry.events(name: "organization.call", since: since), context: context)
        end

        def initialize(events:, context:)
          resolved = Scope.resolve(context: context)
          @scope = {
            "tenant_key" => resolved.tenant_key || "__global__",
            "account_id" => resolved.account_id
          }.freeze
          scoped = Array(events).select do |event|
            (event.dims[:tenant] || "__global__").to_s == @scope["tenant_key"].to_s &&
              event.dims[:account_id].to_s == @scope["account_id"].to_s
          end
          raise HarnessExperimentError, "organization telemetry is empty" if scoped.empty?
          if scoped.size > DelegationDiagnostics::MAX_CALLS
            raise HarnessExperimentError, "organization telemetry exceeds trace bounds"
          end

          @traces = build_traces(scoped)
          @agents = build_agents(scoped)
          @incomplete = missing_measurements(scoped)
          freeze
        end

        def analyze(minimum_requests: 5, coupling_threshold: 0.8, context: Context.resolve)
          expected = Scope.resolve(context: context)
          unless (expected.tenant_key || "__global__").to_s == scope["tenant_key"].to_s &&
                 expected.account_id.to_s == scope["account_id"].to_s
            raise HarnessIntegrityError, "organization trace scope mismatch"
          end
          DelegationDiagnostics.analyze(
            traces: traces, agents: agents, context: context,
            minimum_requests: minimum_requests, coupling_threshold: coupling_threshold
          )
        end

        def to_h
          Harness.deep_freeze(
            "schema_version" => 1, "scope" => scope, "traces" => traces,
            "agents" => agents, "incomplete" => incomplete
          )
        end

        def digest = Harness.digest(to_h)

        private

        def build_traces(events)
          rows = events.group_by { |event| event.dims.fetch(:request_digest) }.map do |request_digest, calls|
            starts = calls.map { |event| start_time(event) }
            origin = starts.min
            {
              id: request_digest, tenant_key: scope["tenant_key"], account_id: scope["account_id"],
              calls: calls.sort_by { |event| [start_time(event), event.dims.fetch(:agent).to_s] }.map do |event|
                measures = event.measures
                {
                  agent: event.dims.fetch(:agent),
                  start_ms: ((start_time(event) - origin) * 1_000).round(3),
                  duration_ms: measures.fetch(:duration_ms, 0),
                  cost_usd: measures.fetch(:cost_usd, 0),
                  input_tokens: measures.fetch(:input_tokens, 0),
                  output_tokens: measures.fetch(:output_tokens, 0),
                  context_bytes: measures[:context_bytes], retries: measures[:retries],
                  verifier_rejections: measures[:verifier_rejections],
                  duplicate_work: measures[:duplicate_work], handoffs: measures[:handoffs],
                  failed_handoffs: measures[:failed_handoffs],
                  context_retention: measures[:context_retention], quality: measures[:quality],
                  success: measures[:success],
                  capability: event.dims[:capability], handoff_from: event.dims[:handoff_from],
                  model_profile: event.dims[:model_profile], toolset_digest: event.dims[:toolset_digest],
                  skills_digest: event.dims[:skills_digest], policy_digest: event.dims[:policy_digest]
                }.compact
              end
            }
          end
          Harness.deep_freeze(rows.sort_by { |row| row.fetch(:id) })
        end

        def build_agents(events)
          rows = events.group_by { |event| event.dims.fetch(:agent).to_s }.sort.map do |name, calls|
            capabilities = calls.filter_map { |event| event.dims[:capability]&.to_s }.uniq.sort
            {
              name: name, role: calls.first.dims.fetch(:role, "unknown"),
              context_group: calls.first.dims[:organization_id], capabilities: capabilities,
              independent_context: calls.any? { |event| event.dims[:independent_context] == true },
              permission_boundary: calls.any? { |event| event.dims[:permission_boundary] == true }
            }
          end
          Harness.deep_freeze(rows)
        end

        def missing_measurements(events)
          Harness.deep_freeze(%i[success context_bytes].to_h do |name|
            [name.to_s, events.count { |event| !event.measures.key?(name) }]
          end)
        end

        def start_time(event)
          event.occurred_at.to_f - event.measures.fetch(:duration_ms, 0).to_f / 1_000
        end
      end
    end
  end
end
