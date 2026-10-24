# frozen_string_literal: true

module Agentkit
  module Harness
    # Bounded import of peer delegation spans. Recommendations are diagnostic:
    # temporal co-occurrence is not proof that a migration will improve quality.
    class DelegationDiagnostics
      MAX_TRACES = 200
      MAX_CALLS = 2_000
      MAX_CALLS_PER_TRACE = 64
      MAX_AGENTS = 64
      ROLES = %w[router planner domain research verifier unknown].freeze

      class Report
        attr_reader :data
        def initialize(data)
          @data = Harness.deep_freeze(DeclarativeData.normalize(data, label: "delegation report"))
          freeze
        end
        def to_h = data
        def digest = Harness.digest(data)
        def required_chains = data.fetch("observed_chains").map { |entry| entry.fetch("chain") }
      end

      def self.analyze(traces:, agents:, context: Context.resolve, minimum_requests: 5, coupling_threshold: 0.8)
        new(context: context, minimum_requests: minimum_requests,
            coupling_threshold: coupling_threshold).analyze(traces: traces, agents: agents)
      end

      def initialize(context:, minimum_requests:, coupling_threshold:)
        @context = context
        scope = Scope.resolve(context: context)
        @scope = { "tenant_key" => scope.tenant_key || "__global__", "account_id" => scope.account_id }
        @minimum_requests = Integer(minimum_requests)
        @threshold = Float(coupling_threshold)
        unless @minimum_requests >= 2 && @threshold.finite? && @threshold.positive? && @threshold <= 1
          raise HarnessExperimentError, "invalid delegation diagnostic thresholds"
        end
      end

      def analyze(traces:, agents:)
        unless traces.is_a?(Array) && traces.size.between?(1, MAX_TRACES) &&
               agents.is_a?(Array) && agents.size.between?(1, MAX_AGENTS)
          raise HarnessExperimentError, "delegation traces/catalog exceed bounds or are empty"
        end
        catalog = agents.to_h do |raw|
          raise HarnessExperimentError, "delegation catalog entries must be objects" unless raw.is_a?(Hash)
          data = Harness.stringify_keys(raw)
          name = ArchitectureEvaluation.name!(data.fetch("name"))
          role = data.fetch("role", "unknown").to_s
          raise HarnessExperimentError, "unknown delegation role" unless ROLES.include?(role)
          flags = %w[independent_context permission_boundary].to_h do |key|
            value = data.fetch(key, false)
            raise HarnessExperimentError, "delegation flags must be boolean" unless [true, false].include?(value)
            [key, value]
          end
          group = data["context_group"]
          ArchitectureEvaluation.name!(group) if group
          [name, flags.merge("name" => name, "role" => role, "context_group" => group)]
        end
        raise HarnessExperimentError, "duplicate delegation agent name" unless catalog.size == agents.size
        seen = {}
        count = 0
        normalized = traces.map do |raw|
          raise HarnessExperimentError, "delegation traces must be objects" unless raw.is_a?(Hash)
          data = Harness.stringify_keys(raw)
          unless data["tenant_key"].to_s == @scope["tenant_key"].to_s &&
                 data["account_id"].to_s == @scope["account_id"].to_s
            raise HarnessIntegrityError, "delegation trace scope mismatch"
          end
          id = data.fetch("id")
          unless id.is_a?(String) && id.bytesize.between?(1, 128) && !seen[id]
            raise HarnessExperimentError, "duplicate or invalid delegation request id"
          end
          seen[id] = true
          calls = data.fetch("calls")
          unless calls.is_a?(Array) && calls.size.between?(1, MAX_CALLS_PER_TRACE)
            raise HarnessExperimentError, "delegation calls exceed per-request bounds"
          end
          count += calls.size
          raise HarnessExperimentError, "delegation calls exceed total bound" if count > MAX_CALLS
          { "id_digest" => Harness.digest(id), "calls" => calls.map { |call| normalize_call(call, catalog) }
                                                          .sort_by { |call| [call["start_ms"], call["agent"]] } }
        end.sort_by { |trace| trace["id_digest"] }
        pairs = pair_rows(normalized, catalog)
        chains = normalized.filter_map do |trace|
          calls = trace.fetch("calls")
          next unless calls.each_cons(2).all? { |left, right| finish(left) <= right["start_ms"] }
          next if calls.size > ArchitectureEvaluation::MAX_CHAIN
          calls.map { |call| call.fetch("agent") }
        end
        agent_rows = catalog.keys.sort.map do |name|
          requests = normalized.select { |trace| trace["calls"].any? { |call| call["agent"] == name } }
          calls = requests.flat_map { |trace| trace["calls"].select { |call| call["agent"] == name } }
          descriptor = catalog.fetch(name)
          concurrent = pairs.any? { |pair| pair["agents"].include?(name) && pair["overlap_requests"].positive? }
          shared = pairs.any? do |pair|
            pair["agents"].include?(name) && pair["shared_context"] && pair["serial_requests"] >= @minimum_requests
          end
          decision, reason = verdict(descriptor, requests.size, concurrent, shared)
          descriptor.merge("requests" => requests.size, "calls" => calls.size,
                           "duration_ms" => calls.sum { |call| call["duration_ms"] },
                           "usage" => usage(calls), "decision" => decision, "reason" => reason)
        end
        report = Report.new(
          "schema_version" => 1, "kind" => "delegation_diagnostics", "scope" => @scope,
          "source_digest" => Harness.digest(traces: normalized, agents: catalog),
          "minimum_requests" => @minimum_requests, "coupling_threshold" => @threshold,
          "request_count" => normalized.size, "call_count" => count,
          "usage" => usage(normalized.flat_map { |trace| trace["calls"] }),
          "observed_chains" => chains.tally.sort.map { |chain, requests| { "chain" => chain, "requests" => requests } },
          "nonlinear_requests" => normalized.size - chains.size,
          "agents" => agent_rows, "pairs" => pairs
        )
        if JSON.generate(report.to_h).bytesize > @context.config.harness.max_checkpoint_bytes
          raise HarnessPersistenceError, "delegation report exceeds checkpoint byte limit"
        end
        report
      rescue KeyError => error
        raise HarnessExperimentError, "incomplete delegation trace: #{error.key}"
      end

      private

      def normalize_call(raw, catalog)
        raise HarnessExperimentError, "delegation calls must be objects" unless raw.is_a?(Hash)
        data = Harness.stringify_keys(raw)
        name = ArchitectureEvaluation.name!(data.fetch("agent"))
        raise HarnessExperimentError, "delegation agent is not in catalog" unless catalog.key?(name)
        result = { "agent" => name }
        %w[start_ms duration_ms].each { |key| result[key] = nonnegative!(data.fetch(key), key) }
        %w[cost_usd input_tokens output_tokens context_bytes].each do |key|
          next unless data.key?(key)
          number = nonnegative!(data[key], key)
          if key != "cost_usd" && number != number.to_i
            raise HarnessExperimentError, "delegation counts must be integers"
          end
          result[key] = key == "cost_usd" ? number : number.to_i
        end
        unless finish(result).finite?
          raise HarnessExperimentError, "delegation span overflow"
        end
        result
      end

      def nonnegative!(value, label)
        number = Float(value)
        raise HarnessExperimentError, "delegation #{label} must be finite and nonnegative" unless number.finite? && number >= 0
        number
      rescue ArgumentError, TypeError
        raise HarnessExperimentError, "delegation #{label} must be numeric"
      end

      def finish(call) = call.fetch("start_ms") + call.fetch("duration_ms")

      def usage(calls)
        %w[cost_usd input_tokens output_tokens context_bytes].to_h do |key|
          known = calls.select { |call| call.key?(key) }
          [key, { "reported" => known.sum { |call| call[key] }, "known_calls" => known.size,
                  "complete" => known.size == calls.size && !calls.empty? }]
        end
      end

      def protected?(agent)
        agent["role"] == "verifier" || agent["permission_boundary"] || agent["independent_context"]
      end

      def verdict(agent, requests, concurrent, shared)
        return ["insufficient_evidence", "too_few_requests"] if requests < @minimum_requests
        return ["keep_as_tool", "verification_or_isolation"] if protected?(agent)
        return ["keep_as_tool", "observed_parallel_work"] if concurrent
        if %w[router planner domain].include?(agent["role"]) && shared
          return ["fold_candidate", "shared_context_specialist"]
        end
        ["inspect", "context_boundary_not_established"]
      end

      def pair_rows(traces, catalog)
        catalog.keys.sort.combination(2).filter_map do |left, right|
          together = 0
          union = 0
          serial = 0
          overlaps = 0
          traces.each do |trace|
            calls = trace.fetch("calls")
            a = calls.select { |call| call["agent"] == left }
            b = calls.select { |call| call["agent"] == right }
            union += 1 if a.any? || b.any?
            next if a.empty? || b.empty?
            together += 1
            overlapping = a.any? { |x| b.any? { |y| x["start_ms"] < finish(y) && y["start_ms"] < finish(x) } }
            adjacent = calls.each_cons(2).any? do |x, y|
              [x["agent"], y["agent"]].sort == [left, right] && finish(x) <= y["start_ms"]
            end
            overlaps += 1 if overlapping
            serial += 1 if adjacent && !overlapping
          end
          next if together.zero?
          shared = catalog[left]["context_group"] &&
                   catalog[left]["context_group"] == catalog[right]["context_group"]
          merge = together >= @minimum_requests && serial.to_f / union >= @threshold &&
                  overlaps.zero? && shared && !protected?(catalog[left]) && !protected?(catalog[right]) &&
                  [left, right].all? { |name| %w[router planner domain].include?(catalog[name]["role"]) }
          { "agents" => [left, right], "requests" => together,
            "shared_request_rate" => together.to_f / union, "serial_requests" => serial,
            "overlap_requests" => overlaps, "shared_context" => !!shared,
            "decision" => merge ? "merge_candidate" : "inspect",
            "reason" => merge ? "frequent_serial_shared_context" : "merge_not_supported" }
        end
      end
    end
  end
end
