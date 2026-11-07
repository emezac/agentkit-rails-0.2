# frozen_string_literal: true

module Agentkit
  module Memory
    # Offline paired evaluation. Runners never receive fixture expectations;
    # grading and cost reporting are trusted host responsibilities, not proof.
    class Evaluation
      K = Knowledge
      B = K::Boundary
      ARMS = %w[search_only current_memory consolidated_memory].freeze

      def self.compare(cases:, runner:, grader:, consolidation_cost_microusd: 0)
        cases = B.data(cases)
        unless cases.is_a?(Array) && cases.size.between?(1, 200) && [runner, grader].all? { |v| v.respond_to?(:call) } && consolidation_cost_microusd.is_a?(Integer) && consolidation_cost_microusd >= 0
          raise K::InvalidContract, "bounded fixtures, callbacks and nonnegative consolidation cost required"
        end
        cases.each do |test|
          K::Snapshot.exact_keys!(test, %w[id input expected])
          K.text(test["id"])
        end
        raise K::InvalidContract, "fixtures exceed 2 MiB" if JSON.generate(cases).bytesize > 2_097_152
        raise K::InvalidContract, "duplicate fixture IDs" unless cases.map { |c| c["id"] }.uniq.size == cases.size
        rows = cases.flat_map do |test|
          ARMS.map do |arm|
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            begin
              output = B.data(runner.call(arm, test.fetch("input")))
              K::Snapshot.exact_keys!(output, %w[answer evidence_ids tokens cost_microusd])
              unless output["answer"].is_a?(String) && output["answer"].bytesize <= 65_536 && output["evidence_ids"].is_a?(Array) && output["evidence_ids"].size <= 64 && output["evidence_ids"].all? { |v| v.is_a?(String) && v.bytesize <= 4096 } && %w[tokens cost_microusd].all? { |f| output[f].is_a?(Integer) && output[f] >= 0 }
                raise K::InvalidContract, "invalid runner result"
              end
              grade = B.data(grader.call(output, test.fetch("expected")))
              K::Snapshot.exact_keys!(grade, %w[correct supported stale_used cross_scope])
              raise K::InvalidContract, "boolean grades required" unless grade.values.all? { |v| v == true || v == false }
              { "id" => test["id"], "arm" => arm, "grade" => grade, "output_digest" => K.digest(output),
                "tokens" => output["tokens"], "cost_microusd" => output["cost_microusd"],
                "latency_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
                "passed" => grade["correct"] && grade["supported"] && !grade["stale_used"] && !grade["cross_scope"] }
            rescue StandardError => error
              { "id" => test["id"], "arm" => arm, "passed" => false, "error_class" => error.class.name }
            end
          end
        end
        totals = ARMS.to_h do |arm|
          runs = rows.select { |r| r["arm"] == arm }
          [arm, { "total" => runs.size, "passed" => runs.count { |r| r["passed"] },
            "errors" => runs.count { |r| r["error_class"] }, "tokens" => runs.sum { |r| r.fetch("tokens", 0) },
            "reported_cost_microusd" => runs.sum { |r| r.fetch("cost_microusd", 0) } + (arm == "consolidated_memory" ? consolidation_cost_microusd : 0),
            "cost_complete" => runs.none? { |r| r["error_class"] } }]
        end
        B.data(cases_digest: K.digest(cases), rows: rows, totals: totals, consolidation_cost_microusd: consolidation_cost_microusd,
          authorizes: false, guarantee: "host_graded_offline_comparison_not_causal_proof")
      end
    end
  end
end
