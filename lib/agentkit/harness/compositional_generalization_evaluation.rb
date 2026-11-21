# frozen_string_literal: true

module Agentkit
  module Harness
    # Opt-in, redacted evaluation of whether a harness reuses the same
    # decomposition on longer inputs or a different domain. The host grades
    # outcomes; AgentKit stores only bounded identifiers, counters and rates.
    class CompositionalGeneralizationEvaluation
      NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.:\/-]{0,127}\z/
      AXES = %w[length domain].freeze
      STAGES = %w[source target].freeze
      MAX_PAIRS = 200
      MAX_COUNTER = 1_000_000_000_000
      ROOT_KEYS = %w[turns input_tokens output_tokens context_peak_bytes].freeze
      SUBAGENT_KEYS = %w[calls turns input_tokens output_tokens context_peak_bytes].freeze
      SUMMARY_KEYS = %w[
        success_rate successes repetitions delegation_rate
        local_subtasks_correct local_subtasks_total local_accuracy
        root subagents subcalls_mean limit_exhaustion_rate quality cost latency
      ].freeze

      attr_reader :minimum_source_success_rate, :minimum_target_success_rate,
                  :minimum_local_accuracy, :max_transfer_drop,
                  :minimum_target_lift, :max_family_regressions,
                  :maximum_limit_exhaustion_rate, :require_no_delegation_baseline

      def initialize(minimum_source_success_rate: 0.5, minimum_target_success_rate: 0.5,
                     minimum_local_accuracy: 0.8, max_transfer_drop: 0.2,
                     minimum_target_lift: 0.0, max_family_regressions: 0,
                     maximum_limit_exhaustion_rate: 0.0,
                     require_no_delegation_baseline: true)
        @minimum_source_success_rate = rate!(minimum_source_success_rate, "minimum_source_success_rate")
        @minimum_target_success_rate = rate!(minimum_target_success_rate, "minimum_target_success_rate")
        @minimum_local_accuracy = rate!(minimum_local_accuracy, "minimum_local_accuracy")
        @max_transfer_drop = rate!(max_transfer_drop, "max_transfer_drop")
        @minimum_target_lift = signed_rate!(minimum_target_lift, "minimum_target_lift")
        @maximum_limit_exhaustion_rate = rate!(
          maximum_limit_exhaustion_rate, "maximum_limit_exhaustion_rate"
        )
        unless max_family_regressions.nil? ||
               (max_family_regressions.is_a?(Integer) && max_family_regressions >= 0)
          raise HarnessExperimentError, "max_family_regressions must be a nonnegative integer or nil"
        end
        unless [true, false].include?(require_no_delegation_baseline)
          raise HarnessExperimentError, "require_no_delegation_baseline must be boolean"
        end

        @max_family_regressions = max_family_regressions
        @require_no_delegation_baseline = require_no_delegation_baseline
        freeze
      end

      def to_h
        {
          "schema_version" => 1,
          "minimum_source_success_rate" => minimum_source_success_rate,
          "minimum_target_success_rate" => minimum_target_success_rate,
          "minimum_local_accuracy" => minimum_local_accuracy,
          "max_transfer_drop" => max_transfer_drop,
          "minimum_target_lift" => minimum_target_lift,
          "max_family_regressions" => max_family_regressions,
          "maximum_limit_exhaustion_rate" => maximum_limit_exhaustion_rate,
          "require_no_delegation_baseline" => require_no_delegation_baseline
        }
      end

      # compositional_generalization metadata:
      #   family, pair_id, axis(length|domain), stage(source|target), domain,
      #   strategy, scale, critical(boolean), local_subtasks(boolean)
      def task_spec(task)
        raw = task.metadata.fetch("compositional_generalization") do
          raise HarnessExperimentError, "task is missing compositional_generalization metadata"
        end
        raise HarnessExperimentError, "compositional metadata must be an object" unless raw.is_a?(Hash)

        data = Harness.stringify_keys(raw)
        allowed = %w[family pair_id axis stage domain strategy scale critical local_subtasks]
        unless (data.keys - allowed).empty?
          raise HarnessExperimentError, "compositional metadata contains unknown fields"
        end
        Harness.deep_freeze(
          "family" => name!(data.fetch("family"), "family"),
          "pair_id" => name!(data.fetch("pair_id"), "pair_id"),
          "axis" => enum!(data.fetch("axis"), AXES, "axis"),
          "stage" => enum!(data.fetch("stage"), STAGES, "stage"),
          "domain" => name!(data.fetch("domain"), "domain"),
          "strategy" => name!(data.fetch("strategy"), "strategy"),
          "scale" => positive!(data.fetch("scale"), "scale"),
          "critical" => boolean!(data.fetch("critical", false), "critical"),
          "local_subtasks" => boolean!(data.fetch("local_subtasks", true), "local_subtasks")
        )
      rescue KeyError => error
        raise HarnessExperimentError, "compositional metadata is missing #{error.key}"
      end

      # Deliberately excludes prompts, answers, labels, trajectories and error text.
      def normalize_outcome(value, task:)
        spec = task_spec(task)
        data = DeclarativeData.normalize(
          value, label: "compositional outcome", error_class: HarnessExperimentError
        )
        allowed = %w[success subtasks root subagents subcalls limit_exhausted delegation_enabled]
        unless data.is_a?(Hash) && (data.keys - allowed).empty? && (allowed - data.keys).empty?
          raise HarnessExperimentError, "compositional outcome fields do not match the contract"
        end

        subtasks = counters!(data.fetch("subtasks"), %w[correct total], "subtasks")
        raise HarnessExperimentError, "subtask correct cannot exceed total" if subtasks["correct"] > subtasks["total"]
        if spec["local_subtasks"] && subtasks["total"].zero?
          raise HarnessExperimentError, "local-subtask tasks require graded subtask counters"
        end
        root = counters!(data.fetch("root"), ROOT_KEYS, "root")
        subagents = counters!(data.fetch("subagents"), SUBAGENT_KEYS, "subagents")
        subcalls = counter!(data.fetch("subcalls"), "subcalls")
        if subcalls < subagents.fetch("calls")
          raise HarnessExperimentError, "subcalls cannot be smaller than subagent calls"
        end
        delegation_enabled = boolean!(data.fetch("delegation_enabled"), "delegation_enabled")
        unless delegation_enabled || (subcalls.zero? && subagents.values.all?(&:zero?))
          raise HarnessExperimentError, "disabled delegation must report zero subagent activity"
        end

        Harness.deep_freeze(
          "success" => boolean!(data.fetch("success"), "success"),
          "subtasks" => subtasks, "root" => root, "subagents" => subagents,
          "subcalls" => subcalls,
          "limit_exhausted" => boolean!(data.fetch("limit_exhausted"), "limit_exhausted"),
          "delegation_enabled" => delegation_enabled
        )
      rescue KeyError => error
        raise HarnessExperimentError, "compositional outcome is missing #{error.key}"
      end

      def summarize(probes, task:)
        rows = Array(probes)
        raise HarnessExperimentError, "compositional summary requires at least one probe" if rows.empty?

        outcomes = rows.map do |probe|
          normalize_outcome(probe.fetch("compositional_evaluation"), task: task)
        rescue KeyError
          raise HarnessExperimentError, "probe is missing compositional_evaluation"
        end
        repetitions = outcomes.size
        successes = outcomes.count { |outcome| outcome.fetch("success") }
        correct = outcomes.sum { |outcome| outcome.dig("subtasks", "correct") }
        total = outcomes.sum { |outcome| outcome.dig("subtasks", "total") }

        Harness.deep_freeze(
          "success_rate" => successes.to_f / repetitions,
          "successes" => successes, "repetitions" => repetitions,
          "delegation_rate" => outcomes.count { |outcome| outcome.fetch("delegation_enabled") }.to_f / repetitions,
          "local_subtasks_correct" => correct, "local_subtasks_total" => total,
          "local_accuracy" => total.zero? ? nil : correct.to_f / total,
          "root" => mean_counters(outcomes, "root", ROOT_KEYS),
          "subagents" => mean_counters(outcomes, "subagents", SUBAGENT_KEYS),
          "subcalls_mean" => mean(outcomes.map { |outcome| outcome.fetch("subcalls") }),
          "limit_exhaustion_rate" => outcomes.count { |outcome| outcome.fetch("limit_exhausted") }.to_f / repetitions,
          "quality" => mean_metric(rows, "quality"),
          "cost" => mean_metric(rows, "cost"),
          "latency" => mean_metric(rows, "latency")
        )
      end

      # Source-task gate used for selection. Transfer is evaluated only after
      # the untouched target holdout is available.
      def training_compare(incumbent:, candidate:, tasks:)
        source_tasks = validated_stage_tasks(tasks, "source")
        before = summaries_for(incumbent, source_tasks)
        after = summaries_for(candidate, source_tasks)
        rows = source_tasks.map do |task|
          task_report(task, before.fetch(task.digest), after.fetch(task.digest), stage: "source")
        end
        families = family_reports(rows)
        baseline_clean = no_delegation?(before.values)
        reasons = rows.flat_map { |row| row.fetch("reasons") }
        reasons << "baseline_delegated" if require_no_delegation_baseline && !baseline_clean
        append_family_regression_reason!(reasons, families)

        Harness.deep_freeze(
          "allowed" => reasons.empty?, "reasons" => reasons.uniq.sort,
          "baseline_no_delegation" => baseline_clean, "task_count" => rows.size,
          "family_regressions" => families.count { |family| family.fetch("regressed") },
          "families" => families, "tasks" => rows,
          "telemetry" => telemetry_report(before.values, after.values)
        )
      end

      # Cross-phase gate: source tasks are training evidence and matched target
      # tasks are independent holdout evidence.
      def compare(training_incumbent:, training_candidate:, holdout_incumbent:, holdout_candidate:,
                  training_tasks:, holdout_tasks:)
        pairs = validated_pairs(training_tasks, holdout_tasks)
        baseline_source = summaries_for(training_incumbent, pairs.map(&:first))
        candidate_source = summaries_for(training_candidate, pairs.map(&:first))
        baseline_target = summaries_for(holdout_incumbent, pairs.map { |pair| pair[1] })
        candidate_target = summaries_for(holdout_candidate, pairs.map { |pair| pair[1] })
        baseline_clean = no_delegation?(baseline_source.values + baseline_target.values)

        rows = pairs.map do |source_task, target_task, spec|
          pair_report(
            source_task: source_task, target_task: target_task, spec: spec,
            baseline_source: baseline_source.fetch(source_task.digest),
            candidate_source: candidate_source.fetch(source_task.digest),
            baseline_target: baseline_target.fetch(target_task.digest),
            candidate_target: candidate_target.fetch(target_task.digest)
          )
        end
        families = family_reports(rows, target: true)
        reasons = rows.flat_map { |row| row.fetch("reasons") }
        reasons << "baseline_delegated" if require_no_delegation_baseline && !baseline_clean
        append_family_regression_reason!(reasons, families)

        Harness.deep_freeze(
          "allowed" => reasons.empty?, "reasons" => reasons.uniq.sort,
          "baseline_no_delegation" => baseline_clean,
          "pair_count" => rows.size, "family_count" => families.size,
          "family_regressions" => families.count { |family| family.fetch("regressed") },
          "axes" => AXES.to_h { |axis| [axis, rows.count { |row| row.fetch("axis") == axis }] },
          "families" => families, "pairs" => rows,
          "telemetry" => {
            "training" => telemetry_report(baseline_source.values, candidate_source.values),
            "holdout" => telemetry_report(baseline_target.values, candidate_target.values)
          }
        )
      end

      # Construction-time validation prevents an expensive study from running
      # before a missing or structurally invalid source/target pair is found.
      def validate_task_sets!(training_tasks:, holdout_tasks:)
        validated_pairs(training_tasks, holdout_tasks)
        true
      end

      private

      def validated_stage_tasks(tasks, stage)
        rows = Array(tasks)
        if rows.empty? || rows.size > MAX_PAIRS
          raise HarnessExperimentError, "compositional evaluation requires 1..#{MAX_PAIRS} tasks"
        end
        seen = {}
        rows.each do |task|
          spec = task_spec(task)
          raise HarnessExperimentError, "#{stage} task has the wrong compositional stage" unless spec["stage"] == stage
          raise HarnessExperimentError, "duplicate compositional pair id" if seen.key?(spec["pair_id"])
          seen[spec["pair_id"]] = true
        end
        rows
      end

      def validated_pairs(training_tasks, holdout_tasks)
        sources = validated_stage_tasks(training_tasks, "source")
        targets = validated_stage_tasks(holdout_tasks, "target")
        source_rows = sources.to_h { |task| [task_spec(task).fetch("pair_id"), task] }
        target_rows = targets.to_h { |task| [task_spec(task).fetch("pair_id"), task] }
        unless source_rows.keys.sort == target_rows.keys.sort
          raise HarnessExperimentError, "source and target pair ids must match exactly"
        end

        source_rows.keys.sort.map do |pair_id|
          source_task = source_rows.fetch(pair_id)
          target_task = target_rows.fetch(pair_id)
          source = task_spec(source_task)
          target = task_spec(target_task)
          %w[family axis strategy critical local_subtasks].each do |field|
            unless source.fetch(field) == target.fetch(field)
              raise HarnessExperimentError, "paired tasks disagree on #{field}"
            end
          end
          if source["axis"] == "length"
            unless source["domain"] == target["domain"] && target["scale"] > source["scale"]
              raise HarnessExperimentError, "length pairs require one domain and a larger target scale"
            end
          elsif source["domain"] == target["domain"] || source["scale"] != target["scale"]
            raise HarnessExperimentError, "domain pairs require distinct domains at the same scale"
          end
          [source_task, target_task, source]
        end
      end

      def summaries_for(evaluation, tasks)
        values = if evaluation.respond_to?(:compositional_outcomes)
                   evaluation.compositional_outcomes
                 elsif evaluation.respond_to?(:task_outcomes)
                   evaluation.task_outcomes
                 else
                   evaluation
                 end
        raise HarnessIntegrityError, "compositional evaluation outcomes are missing" unless values.respond_to?(:fetch)

        tasks.to_h do |task|
          raw = values.fetch(task.digest) { raise HarnessIntegrityError, "compositional task outcome is missing" }
          [task.digest, normalize_summary(raw)]
        end
      end

      def normalize_summary(raw)
        data = Harness.stringify_keys(raw)
        unless data.is_a?(Hash) && (data.keys - SUMMARY_KEYS).empty? && (SUMMARY_KEYS - data.keys).empty?
          raise HarnessIntegrityError, "invalid compositional task summary"
        end
        repetitions = positive_integer!(data["repetitions"], "summary repetitions")
        successes = counter!(data["successes"], "summary successes")
        correct = counter!(data["local_subtasks_correct"], "summary local correct")
        total = counter!(data["local_subtasks_total"], "summary local total")
        raise HarnessIntegrityError, "invalid compositional task counters" if successes > repetitions || correct > total

        success_rate = rate!(data["success_rate"], "summary success_rate")
        delegation_rate = rate!(data["delegation_rate"], "summary delegation_rate")
        accuracy = data["local_accuracy"].nil? ? nil : rate!(data["local_accuracy"], "summary local_accuracy")
        exhaustion = rate!(data["limit_exhaustion_rate"], "summary limit_exhaustion_rate")
        unless close?(success_rate, successes.to_f / repetitions) &&
               ((total.zero? && accuracy.nil?) || (!total.zero? && accuracy && close?(accuracy, correct.to_f / total)))
          raise HarnessIntegrityError, "compositional task rates do not match counters"
        end

        Harness.deep_freeze(
          "success_rate" => success_rate, "successes" => successes, "repetitions" => repetitions,
          "delegation_rate" => delegation_rate,
          "local_subtasks_correct" => correct, "local_subtasks_total" => total,
          "local_accuracy" => accuracy,
          "root" => mean_summary_counters!(data["root"], ROOT_KEYS, "summary root"),
          "subagents" => mean_summary_counters!(data["subagents"], SUBAGENT_KEYS, "summary subagents"),
          "subcalls_mean" => nonnegative!(data["subcalls_mean"], "summary subcalls_mean"),
          "limit_exhaustion_rate" => exhaustion,
          "quality" => nonnegative!(data["quality"], "summary quality"),
          "cost" => nonnegative!(data["cost"], "summary cost"),
          "latency" => nonnegative!(data["latency"], "summary latency")
        )
      rescue HarnessExperimentError => error
        raise HarnessIntegrityError, error.message
      end

      def task_report(task, baseline, candidate, stage:)
        spec = task_spec(task)
        threshold = stage == "source" ? minimum_source_success_rate : minimum_target_success_rate
        reasons = common_reasons(candidate, spec)
        reasons << "#{stage}_success_below_threshold" if candidate.fetch("success_rate") < threshold
        if spec.fetch("critical") && candidate.fetch("success_rate") < baseline.fetch("success_rate")
          reasons << "critical_task_regressed"
        end
        {
          "task_digest" => task.digest, "pair_id" => spec.fetch("pair_id"),
          "family" => spec.fetch("family"), "axis" => spec.fetch("axis"),
          "stage" => stage, "critical" => spec.fetch("critical"),
          "baseline_success_rate" => baseline.fetch("success_rate"),
          "candidate_success_rate" => candidate.fetch("success_rate"),
          "success_delta" => candidate.fetch("success_rate") - baseline.fetch("success_rate"),
          "local_accuracy" => candidate.fetch("local_accuracy"),
          "regressed" => candidate.fetch("success_rate") < baseline.fetch("success_rate"),
          "reasons" => reasons.sort
        }
      end

      def pair_report(source_task:, target_task:, spec:, baseline_source:, candidate_source:,
                      baseline_target:, candidate_target:)
        source_rate = candidate_source.fetch("success_rate")
        target_rate = candidate_target.fetch("success_rate")
        transfer_drop = source_rate - target_rate
        target_lift = target_rate - baseline_target.fetch("success_rate")
        reasons = common_reasons(candidate_target, spec)
        reasons << "source_success_below_threshold" if source_rate < minimum_source_success_rate
        reasons << "target_success_below_threshold" if target_rate < minimum_target_success_rate
        reasons << "transfer_drop_exceeded" if transfer_drop > max_transfer_drop
        reasons << "target_lift_below_threshold" if target_lift < minimum_target_lift
        reasons << "critical_task_regressed" if spec.fetch("critical") && target_rate < baseline_target.fetch("success_rate")
        if candidate_source.fetch("limit_exhaustion_rate") > maximum_limit_exhaustion_rate
          reasons << "source_limit_exhaustion_exceeded"
        end

        source_spec = task_spec(source_task)
        target_spec = task_spec(target_task)
        {
          "pair_id" => spec.fetch("pair_id"), "family" => spec.fetch("family"),
          "axis" => spec.fetch("axis"), "strategy" => spec.fetch("strategy"),
          "critical" => spec.fetch("critical"),
          "source_task_digest" => source_task.digest, "target_task_digest" => target_task.digest,
          "source_domain" => source_spec.fetch("domain"), "target_domain" => target_spec.fetch("domain"),
          "source_scale" => source_spec.fetch("scale"), "target_scale" => target_spec.fetch("scale"),
          "baseline_source_success_rate" => baseline_source.fetch("success_rate"),
          "baseline_target_success_rate" => baseline_target.fetch("success_rate"),
          "candidate_source_success_rate" => source_rate,
          "candidate_target_success_rate" => target_rate,
          "generalization_gap" => target_rate - source_rate,
          "transfer_drop" => transfer_drop, "target_lift" => target_lift,
          "local_accuracy" => candidate_target.fetch("local_accuracy"),
          "regressed" => target_rate < baseline_target.fetch("success_rate"),
          "reasons" => reasons.sort
        }
      end

      def common_reasons(summary, spec)
        reasons = []
        if spec.fetch("local_subtasks")
          reasons << "local_accuracy_missing" if summary.fetch("local_accuracy").nil?
          if summary.fetch("local_accuracy") && summary.fetch("local_accuracy") < minimum_local_accuracy
            reasons << "local_accuracy_below_threshold"
          end
        end
        if summary.fetch("limit_exhaustion_rate") > maximum_limit_exhaustion_rate
          reasons << "limit_exhaustion_exceeded"
        end
        reasons
      end

      def family_reports(rows, target: false)
        rows.group_by { |row| row.fetch("family") }.sort.map do |family, entries|
          baseline_key = target ? "baseline_target_success_rate" : "baseline_success_rate"
          candidate_key = target ? "candidate_target_success_rate" : "candidate_success_rate"
          baseline = average(entries, baseline_key)
          candidate = average(entries, candidate_key)
          {
            "family" => family, "task_count" => entries.size,
            "baseline_success_rate" => baseline, "candidate_success_rate" => candidate,
            "success_delta" => candidate - baseline,
            "task_regressions" => entries.count { |entry| entry.fetch("regressed") },
            "regressed" => candidate < baseline
          }
        end
      end

      def append_family_regression_reason!(reasons, families)
        regressions = families.count { |family| family.fetch("regressed") }
        if max_family_regressions && regressions > max_family_regressions
          reasons << "family_regression_limit_exceeded"
        end
      end

      def no_delegation?(summaries)
        summaries.all? do |summary|
          summary.fetch("delegation_rate").zero? && summary.fetch("subcalls_mean").zero? &&
            summary.fetch("subagents").values.all?(&:zero?)
        end
      end

      def telemetry_report(baseline, candidate)
        before = aggregate_telemetry(baseline)
        after = aggregate_telemetry(candidate)
        Harness.deep_freeze("baseline" => before, "candidate" => after,
                            "delta" => numeric_delta(before, after))
      end

      def aggregate_telemetry(summaries)
        {
          "root" => ROOT_KEYS.to_h { |key| [key, mean(summaries.map { |row| row.dig("root", key) })] },
          "subagents" => SUBAGENT_KEYS.to_h { |key| [key, mean(summaries.map { |row| row.dig("subagents", key) })] },
          "subcalls" => mean(summaries.map { |row| row.fetch("subcalls_mean") }),
          "cost" => mean(summaries.map { |row| row.fetch("cost") }),
          "latency" => mean(summaries.map { |row| row.fetch("latency") }),
          "limit_exhaustion_rate" => mean(summaries.map { |row| row.fetch("limit_exhaustion_rate") })
        }
      end

      def numeric_delta(before, after)
        {
          "root" => ROOT_KEYS.to_h { |key| [key, after.dig("root", key) - before.dig("root", key)] },
          "subagents" => SUBAGENT_KEYS.to_h do |key|
            [key, after.dig("subagents", key) - before.dig("subagents", key)]
          end,
          "subcalls" => after.fetch("subcalls") - before.fetch("subcalls"),
          "cost" => after.fetch("cost") - before.fetch("cost"),
          "latency" => after.fetch("latency") - before.fetch("latency"),
          "limit_exhaustion_rate" => after.fetch("limit_exhaustion_rate") - before.fetch("limit_exhaustion_rate")
        }
      end

      def mean_counters(outcomes, key, fields)
        fields.to_h { |field| [field, mean(outcomes.map { |outcome| outcome.dig(key, field) })] }
      end

      def mean_summary_counters!(value, fields, label)
        data = Harness.stringify_keys(value)
        unless data.is_a?(Hash) && data.keys.sort == fields.sort
          raise HarnessIntegrityError, "#{label} counters do not match the contract"
        end
        Harness.deep_freeze(fields.to_h do |field|
          [field, nonnegative!(data.fetch(field), "#{label} #{field}")]
        end)
      end

      def counters!(value, fields, label)
        data = Harness.stringify_keys(value)
        unless data.is_a?(Hash) && data.keys.sort == fields.sort
          raise HarnessExperimentError, "#{label} counters do not match the contract"
        end
        Harness.deep_freeze(fields.to_h { |field| [field, counter!(data.fetch(field), "#{label} #{field}")] })
      end

      def mean_metric(rows, key)
        mean(rows.map { |row| nonnegative!(row.fetch(key), key) })
      rescue KeyError
        raise HarnessExperimentError, "probe is missing #{key}"
      end

      def average(values, key) = mean(values.map { |value| value.fetch(key) })
      def mean(values) = values.sum.to_f / values.size

      def name!(value, label)
        return value if value.is_a?(String) && value.match?(NAME)
        raise HarnessExperimentError, "compositional #{label} must be a bounded identifier"
      end

      def enum!(value, allowed, label)
        text = value.to_s
        return text if allowed.include?(text)
        raise HarnessExperimentError, "invalid compositional #{label}"
      end

      def boolean!(value, label)
        return value if [true, false].include?(value)
        raise HarnessExperimentError, "#{label} must be boolean"
      end

      def rate!(value, label)
        number = finite!(value, label)
        return number if number.between?(0.0, 1.0)
        raise HarnessExperimentError, "#{label} must be between 0 and 1"
      end

      def signed_rate!(value, label)
        number = finite!(value, label)
        return number if number.between?(-1.0, 1.0)
        raise HarnessExperimentError, "#{label} must be between -1 and 1"
      end

      def positive!(value, label)
        number = finite!(value, label)
        return number if number.positive?
        raise HarnessExperimentError, "#{label} must be positive"
      end

      def nonnegative!(value, label)
        number = finite!(value, label)
        return number if number >= 0 && number <= MAX_COUNTER
        raise HarnessExperimentError, "#{label} must be a bounded nonnegative number"
      end

      def finite!(value, label)
        number = Float(value)
        raise HarnessExperimentError, "#{label} must be finite" unless number.finite?
        number
      rescue ArgumentError, TypeError
        raise HarnessExperimentError, "#{label} must be numeric"
      end

      def counter!(value, label)
        return value if value.is_a?(Integer) && value.between?(0, MAX_COUNTER)
        raise HarnessExperimentError, "#{label} must be a bounded nonnegative integer"
      end

      def positive_integer!(value, label)
        return value if value.is_a?(Integer) && value.between?(1, MAX_COUNTER)
        raise HarnessExperimentError, "#{label} must be a bounded positive integer"
      end

      def close?(left, right) = (left - right).abs <= 1e-12
    end
  end
end
