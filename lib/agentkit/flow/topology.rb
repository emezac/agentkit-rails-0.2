# frozen_string_literal: true

module Agentkit
  class Flow
    # Operational topology metrics derived from persisted run/step facts.
    module Topology
      class << self
        def metrics(run)
          steps = Array(run.steps)
          sequential_ms = steps.sum { |step| step.duration_ms.to_f }
          wall_ms = if run.started_at && run.finished_at
                      (run.finished_at - run.started_at) * 1_000.0
                    else
                      sequential_ms
                    end
          fanouts = steps.select { |step| %w[parallel map race].include?(step.kind.to_s) }
          branch_steps = steps.select { |step| step.respond_to?(:parent_step_id) && step.parent_step_id }
          repeats = steps.group_by(&:step_name).sum { |_name, values| [values.size - 1, 0].max }
          durations = steps.map { |step| step.duration_ms.to_f }.select(&:positive?)
          {
            sequential_estimate_ms: sequential_ms.round(3),
            observed_wall_ms: wall_ms.round(3),
            speedup: wall_ms.positive? ? (sequential_ms / wall_ms).round(4) : 0.0,
            fanout_efficiency: fanout_efficiency(fanouts, branch_steps),
            join_wait_ms: steps.select { |step| step.kind.to_s == "join" }.sum { |step| step.duration_ms.to_f }.round(3),
            branches_cancelled: branch_steps.count { |step| step.status.to_s == "cancelled" },
            branches_failed: branch_steps.count { |step| step.status.to_s == "failed" },
            stragglers: fanouts.sum { |step| step.respond_to?(:pending_count) ? step.pending_count.to_i : 0 },
            transition_count: steps.size,
            rework_count: repeats,
            rework_ratio: steps.empty? ? 0.0 : (repeats.to_f / steps.size).round(4),
            reopening_cycles: repeats,
            state_flow: steps.group_by { |step| step.status.to_s }.transform_values(&:size),
            critical_path_variance: variance(durations).round(3)
          }
        end

        private

        def fanout_efficiency(fanouts, branches)
          return 0.0 if fanouts.empty? || branches.empty?

          work = branches.sum { |step| step.duration_ms.to_f }
          span = fanouts.sum { |step| step.duration_ms.to_f }
          max_parallelism = fanouts.sum { |step| [step.respond_to?(:branch_count) ? step.branch_count.to_i : 0, 1].max }
          return 0.0 unless span.positive? && max_parallelism.positive?

          [work / (span * max_parallelism), 1.0].min.round(4)
        end

        def variance(values)
          return 0.0 if values.size < 2

          mean = values.sum / values.size
          values.sum { |value| (value - mean)**2 } / values.size
        end
      end
    end
  end
end
