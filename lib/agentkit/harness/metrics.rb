# frozen_string_literal: true

module Agentkit
  module Harness
    # Operational metrics for the harness itself. These measure acceptance and
    # recovery quality rather than proxying success with token count or speed.
    module Metrics
      module_function

      def record_review(goal_id:, accepted:, first_pass: false, human_minutes: 0,
                        unsupported_claims: 0, context: nil)
        emit(
          "harness.review", goal_id: goal_id, context: context,
          dims: { accepted: !!accepted },
          measures: {
            accepted: !!accepted,
            first_pass_accepted: !!accepted && !!first_pass,
            human_minutes: Float(human_minutes),
            unsupported_claims: Integer(unsupported_claims)
          }
        )
      end

      def record_recovery(goal_id:, success:, repeated: false, attempts: 1, context: nil)
        emit(
          "harness.recovery", goal_id: goal_id, context: context,
          dims: { success: !!success, repeated: !!repeated },
          measures: { success: !!success, repeated: !!repeated, attempts: Integer(attempts) }
        )
      end

      def record_overhead(goal_id:, component:, duration_ms:, cost_usd: 0, context: nil)
        emit(
          "harness.overhead", goal_id: goal_id, context: context,
          dims: { component: component.to_s },
          measures: { duration_ms: Float(duration_ms), cost_usd: Float(cost_usd) }
        )
      end

      def summary(goal_id: nil, since: nil, context: nil)
        ctx = context || Context.current
        filters = {}
        filters[:goal_id] = goal_id.to_s if goal_id
        filters[:tenant] = ctx.tenant_key if ctx&.tenant_key
        rows = Telemetry.events(since: since, dims: filters)
        started = named(rows, "harness.run.started")
        completed = named(rows, "harness.run.completed")
        reviews = named(rows, "harness.review") + named(rows, "harness.verification")
        recoveries = named(rows, "harness.recovery")
        overhead = named(rows, "harness.overhead")

        Harness.deep_freeze(
          {
            runs_started: started.size,
            runs_completed: completed.size,
            completion_rate: ratio(completed.size, started.size),
            first_pass_acceptance_rate: boolean_rate(reviews, :first_pass_accepted),
            review_acceptance_rate: boolean_rate(reviews, :accepted),
            recovery_rate: boolean_rate(recoveries, :success),
            repeated_failure_rate: boolean_rate(recoveries, :repeated),
            human_review_minutes: sum(reviews, :human_minutes),
            human_interventions: reviews.count { |event| event.measures[:human_minutes].to_f.positive? },
            unsupported_completion_claims: sum(reviews, :unsupported_claims).to_i,
            time_to_verified_ms: stats(completed, :duration_ms),
            harness_overhead_ms: stats(overhead, :duration_ms),
            harness_overhead_cost_usd: sum(overhead, :cost_usd)
          }
        )
      end

      def emit(name, goal_id:, context:, dims:, measures:)
        ctx = context || Context.resolve
        Agentkit.with_context(ctx) do
          Telemetry.emit(name, dims: { goal_id: goal_id.to_s }.merge(dims), measures: measures)
        end
      end
      private_class_method :emit

      def named(rows, name) = rows.select { |event| event.name == name }
      private_class_method :named

      def ratio(numerator, denominator)
        return 0.0 if denominator.zero?

        (numerator.to_f / denominator).round(4)
      end
      private_class_method :ratio

      def boolean_rate(rows, measure)
        return 0.0 if rows.empty?

        ratio(rows.count { |event| event.measures[measure] == true }, rows.size)
      end
      private_class_method :boolean_rate

      def sum(rows, measure) = rows.sum { |event| event.measures[measure].to_f }.round(4)
      private_class_method :sum

      def stats(rows, measure)
        Telemetry::Stats.from(rows.filter_map { |event| event.measures[measure] }).to_h
      end
      private_class_method :stats
    end
  end
end
