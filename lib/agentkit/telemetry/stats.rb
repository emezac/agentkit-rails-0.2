# frozen_string_literal: true

module Agentkit
  module Telemetry
    # Descriptive statistics for one probe point. This is the shape the factory
    # reads and the dashboard renders: not just a count, but distribution.
    #
    # v0.1's improvement loop had `AgentLog.failed.group(:agent_name).count` and
    # nothing else — a count cannot tell you whether p95 latency doubled while
    # the mean stayed flat.
    class Stats
      attr_reader :n, :sum, :min, :max, :mean, :stddev, :p50, :p90, :p95, :p99, :histogram

      def self.from(values, buckets: nil)
        values = Array(values).compact.map(&:to_f)
        return empty if values.empty?

        sorted = values.sort
        n      = sorted.size
        sum    = sorted.sum
        mean   = sum / n
        var    = n > 1 ? sorted.sum { |v| (v - mean)**2 } / (n - 1) : 0.0

        new(
          n: n, sum: sum, min: sorted.first, max: sorted.last, mean: mean,
          stddev: Math.sqrt(var),
          p50: percentile(sorted, 0.50), p90: percentile(sorted, 0.90),
          p95: percentile(sorted, 0.95), p99: percentile(sorted, 0.99),
          histogram: histogram_for(sorted, buckets)
        )
      end

      def self.empty
        new(n: 0, sum: 0.0, min: nil, max: nil, mean: nil, stddev: nil,
            p50: nil, p90: nil, p95: nil, p99: nil, histogram: {})
      end

      # Linear-interpolation percentile (same convention as most dashboards).
      def self.percentile(sorted, q)
        return sorted.first if sorted.size == 1

        rank  = q * (sorted.size - 1)
        lower = sorted[rank.floor]
        upper = sorted[rank.ceil]
        (lower + ((upper - lower) * (rank - rank.floor))).round(4)
      end

      # Log-ish buckets by default: good enough for latency and cost, and stable
      # across periods so histograms stay comparable.
      DEFAULT_BUCKETS = [1, 5, 10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000].freeze

      def self.histogram_for(sorted, buckets)
        edges = buckets || DEFAULT_BUCKETS
        counts = Hash.new(0)
        sorted.each do |v|
          edge = edges.find { |e| v <= e }
          counts[edge ? "<=#{edge}" : ">#{edges.last}"] += 1
        end
        counts
      end

      def initialize(**attrs)
        attrs.each { |k, v| instance_variable_set(:"@#{k}", v) }
        freeze
      end

      def empty? = n.zero?

      # Effect size vs. another period, used by the factory's detectors.
      def delta(other, field: :mean)
        a = public_send(field)
        b = other&.public_send(field)
        return nil if a.nil? || b.nil? || b.zero?

        ((a - b) / b.to_f).round(4)
      end

      def to_h
        { n: n, sum: round(sum), min: round(min), max: round(max), mean: round(mean),
          stddev: round(stddev), p50: p50, p90: p90, p95: p95, p99: p99,
          histogram: histogram }
      end

      def to_s
        return "Stats(empty)" if empty?

        format("Stats(n=%d mean=%.1f p50=%.1f p95=%.1f max=%.1f)", n, mean, p50, p95, max)
      end
      alias inspect to_s

      private

      def round(v) = v&.round(4)
    end

    # Two-proportion z-test. The factory refuses to promote a variant on
    # "the LLM said it looked better" — it needs an effect with enough n.
    module Significance
      Z_FOR = { 0.80 => 1.2816, 0.90 => 1.6449, 0.95 => 1.9600, 0.99 => 2.5758 }.freeze

      module_function

      # @return [Hash] {significant:, z:, effect:, p_control:, p_variant:}
      def proportions(control_successes:, control_n:, variant_successes:, variant_n:, confidence: 0.90)
        return { significant: false, reason: :insufficient_samples } if control_n.zero? || variant_n.zero?

        p1 = control_successes.to_f / control_n
        p2 = variant_successes.to_f / variant_n
        pooled = (control_successes + variant_successes).to_f / (control_n + variant_n)
        se = Math.sqrt(pooled * (1 - pooled) * ((1.0 / control_n) + (1.0 / variant_n)))
        return { significant: false, reason: :zero_variance, effect: p2 - p1 } if se.zero?

        z = (p2 - p1) / se
        threshold = Z_FOR.fetch(confidence) { Z_FOR[0.90] }
        {
          significant: z.abs >= threshold,
          z: z.round(4), effect: (p2 - p1).round(4),
          p_control: p1.round(4), p_variant: p2.round(4),
          confidence: confidence
        }
      end
    end
  end
end
