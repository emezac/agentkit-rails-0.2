# frozen_string_literal: true

module Agentkit
  module Harness
    # A deterministic, paired business-process report. Observations come from
    # trusted host measurements; this report never executes either process.
    class BusinessValueEvaluation
      K = Knowledge
      B = K::Boundary
      MEASURES = %w[cost_microusd latency_ms human_seconds tokens].freeze
      PHASES = %w[training holdout].freeze
      ARMS = %w[baseline candidate].freeze

      def initialize(id:, version:, cases:, observations:)
        @id, @version = text(id), text(version)
        raise K::InvalidContract, "bounded cases required" unless cases.is_a?(Array) && cases.size.between?(2, 1_000)
        @cases = cases.map do |item|
          item = B.data(item)
          K::Snapshot.exact_keys!(item, %w[id phase input_digest category])
          %w[id category].each { |field| text(item.fetch(field)) }
          %w[input_digest].each { |field| digest(item.fetch(field)) }
          raise K::InvalidContract, "invalid phase" unless PHASES.include?(item.fetch("phase"))
          item
        end
        ids = @cases.map { |item| item.fetch("id") }
        unless ids.uniq == ids && PHASES.all? { |phase| @cases.any? { |item| item.fetch("phase") == phase } }
          raise K::InvalidContract, "unique cases in training and holdout required"
        end
        raise K::InvalidContract, "bounded paired observations required" unless observations.is_a?(Array) && observations.size == @cases.size * 2
        @observations = observations.map do |item|
          item = B.data(item)
          K::Snapshot.exact_keys!(item, %w[case_id arm input_digest evidence_digest verified safety_failures cost_microusd latency_ms human_seconds tokens])
          %w[case_id arm].each { |field| text(item.fetch(field)) }
          %w[input_digest evidence_digest].each { |field| digest(item.fetch(field)) }
          raise K::InvalidContract, "invalid arm or verified result" unless ARMS.include?(item.fetch("arm")) && [true, false].include?(item.fetch("verified"))
          unless item.fetch("safety_failures").is_a?(Array) && item.fetch("safety_failures").size <= 16 &&
              item.fetch("safety_failures").uniq == item.fetch("safety_failures")
            raise K::InvalidContract, "bounded safety failures required"
          end
          item.fetch("safety_failures").each { |code| text(code) }
          unless MEASURES.all? { |field| item.fetch(field).is_a?(Integer) && item.fetch(field) >= 0 }
            raise K::InvalidContract, "complete nonnegative integer measures required"
          end
          item
        end
        expected = @cases.flat_map { |item| ARMS.map { |arm| [item.fetch("id"), arm] } }
        actual = @observations.map { |item| item.values_at("case_id", "arm") }
        raise K::InvalidContract, "one observation per case and arm required" unless actual.sort == expected.sort
        by_id = @cases.to_h { |item| [item.fetch("id"), item] }
        @observations.each do |item|
          case_contract = by_id.fetch(item.fetch("case_id"))
          raise K::InvalidContract, "observation input differs from case" unless item.fetch("input_digest") == case_contract.fetch("input_digest")
        end
        # A receipt cannot stand in for independent observations of both arms.
        receipts = @observations.map { |item| item.fetch("evidence_digest") }
        raise K::InvalidContract, "unique evidence receipts required" unless receipts.uniq == receipts
        @cases.freeze
        @observations.freeze
      end

      def to_h
        dossier = PHASES.to_h { |phase| [phase, summarize(phase)] }
        B.data(schema: "agentkit.business_value_evaluation.v1", id: @id, version: @version,
          contract_digest: K.digest(B.data(id: @id, version: @version, cases: @cases)),
          observations_digest: K.digest(@observations.sort_by { |row| row.values_at("case_id", "arm") }),
          phases: dossier, comparable: true, causal: false, authorizes: false,
          auto_promoted: false)
      end

      private

      def summarize(phase)
        selected = @cases.select { |item| item.fetch("phase") == phase }
        arms = ARMS.to_h do |arm|
          rows = @observations.select do |item|
            item.fetch("arm") == arm && selected.any? { |test| test.fetch("id") == item.fetch("case_id") }
          end
          passed = rows.count { |item| item.fetch("verified") && item.fetch("safety_failures").empty? }
          cost = rows.sum { |item| item.fetch("cost_microusd") }
          [arm, { "cases" => rows.size, "verified" => passed,
                  "safety_failures" => rows.sum { |item| item.fetch("safety_failures").size },
                  "total_cost_microusd" => cost,
                  "cost_per_verified_microusd" => passed.zero? ? nil : (cost + passed - 1) / passed,
                  "total_human_seconds" => rows.sum { |item| item.fetch("human_seconds") },
                  "total_latency_ms" => rows.sum { |item| item.fetch("latency_ms") },
                  "total_tokens" => rows.sum { |item| item.fetch("tokens") } }]
        end
        baseline, candidate = arms.values_at("baseline", "candidate")
        { "case_count" => selected.size, "arms" => arms,
          "candidate_regressions" => selected.filter_map do |item|
            pair = @observations.select { |row| row.fetch("case_id") == item.fetch("id") }
            before = pair.find { |row| row.fetch("arm") == "baseline" }
            after = pair.find { |row| row.fetch("arm") == "candidate" }
            item.fetch("id") if (before.fetch("verified") && !after.fetch("verified")) ||
              (after.fetch("safety_failures") - before.fetch("safety_failures")).any?
          end,
          "delta" => { "verified" => candidate.fetch("verified") - baseline.fetch("verified"),
                       "cost_microusd" => candidate.fetch("total_cost_microusd") - baseline.fetch("total_cost_microusd"),
                       "human_seconds" => candidate.fetch("total_human_seconds") - baseline.fetch("total_human_seconds"),
                       "latency_ms" => candidate.fetch("total_latency_ms") - baseline.fetch("total_latency_ms") } }
      end

      def text(value)
        raise K::InvalidContract, "bounded text required" unless value.is_a?(String) && value.bytesize.between?(1, 256)
        value
      end

      def digest(value)
        raise K::InvalidContract, "SHA-256 evidence digest required" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
        value
      end
    end
  end
end
