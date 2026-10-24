# frozen_string_literal: true

module Agentkit
  module Harness
    # Opt-in end-to-end outcomes and explicit production-chain coverage.
    # The host grades task success/checks; quality remains a separate metric.
    class ArchitectureEvaluation
      NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.:\/-]{0,127}\z/
      MAX_CHECKS = 64
      MAX_CHAIN = 32
      attr_reader :minimum_success_rate, :max_regressions, :required_chains

      def initialize(minimum_success_rate: 1.0, max_regressions: 0, required_chains: [])
        unless max_regressions.nil? || max_regressions.is_a?(Integer)
          raise HarnessExperimentError, "max_regressions must be an integer or nil"
        end
        @minimum_success_rate = Float(minimum_success_rate)
        @max_regressions = max_regressions.nil? ? nil : Integer(max_regressions)
        unless @minimum_success_rate.finite? && @minimum_success_rate.positive? &&
               @minimum_success_rate <= 1 && (@max_regressions.nil? || @max_regressions >= 0)
          raise HarnessExperimentError, "invalid architecture evaluation thresholds"
        end
        raise HarnessExperimentError, "too many required chains" if Array(required_chains).size > 200
        @required_chains = Harness.deep_freeze(Array(required_chains).map { |chain| self.class.chain!(chain) }.uniq.sort)
        freeze
      end

      def to_h
        { "schema_version" => 1, "minimum_success_rate" => minimum_success_rate,
          "max_regressions" => max_regressions, "required_chains" => required_chains }
      end

      def task_spec(task)
        raw = task.metadata.fetch("architecture", {})
        raise HarnessExperimentError, "task architecture must be an object" unless raw.is_a?(Hash)
        critical = raw.fetch("critical", false)
        unless critical == true || critical == false
          raise HarnessExperimentError, "task critical must be boolean"
        end
        checks = raw.fetch("required_checks", [])
        unless checks.is_a?(Array) && checks.size <= MAX_CHECKS
          raise HarnessExperimentError, "required checks must be a bounded array"
        end
        { "critical" => critical, "required_checks" => checks.map { |name| self.class.name!(name) }.uniq.sort,
          "chain" => raw.key?("chain") ? self.class.chain!(raw["chain"]) : [] }
      end

      def coverage(tasks)
        declared = Array(tasks).map { |task| task_spec(task).fetch("chain") }
        missing = required_chains - declared
        Harness.deep_freeze(
          "required_count" => required_chains.size, "covered_count" => required_chains.size - missing.size,
          "missing_chains" => missing, "complete" => missing.empty?
        )
      end

      def normalize_outcome(value, task:)
        data = DeclarativeData.normalize(value, label: "task evaluation", error_class: HarnessExperimentError)
        unless data.is_a?(Hash) && [true, false].include?(data["success"])
          raise HarnessExperimentError, "task evaluation requires boolean success"
        end
        checks = data.fetch("checks", {})
        unless checks.is_a?(Hash) && checks.size <= MAX_CHECKS &&
               checks.all? { |key, verdict| self.class.name!(key) && [true, false].include?(verdict) }
          raise HarnessExperimentError, "task checks require bounded boolean verdicts"
        end
        required = task_spec(task).fetch("required_checks")
        unless (required - checks.keys).empty?
          raise HarnessExperimentError, "task evaluation is missing required checks"
        end
        Harness.deep_freeze("success" => data.fetch("success"), "checks" => checks)
      end

      def summarize(probes, task:)
        required = task_spec(task).fetch("required_checks")
        outcomes = probes.map { |probe| normalize_outcome(probe.fetch("evaluation"), task: task) }
        failures = required.to_h { |name| [name, outcomes.count { |outcome| outcome.fetch("checks").fetch(name) == false }] }
        successes = outcomes.count { |outcome| outcome["success"] && required.all? { |name| outcome["checks"][name] } }
        { "success_rate" => successes.to_f / probes.size, "successes" => successes,
          "repetitions" => probes.size, "check_failures" => failures,
          "quality" => average(probes, "quality"), "cost" => average(probes, "cost"),
          "latency" => average(probes, "latency") }
      end

      def compare(incumbent:, candidate:, tasks:)
        rows = tasks.map do |task|
          before = incumbent.task_outcomes.fetch(task.digest)
          after = candidate.task_outcomes.fetch(task.digest)
          spec = task_spec(task)
          passed_before = before.fetch("success_rate") >= minimum_success_rate
          passed_after = after.fetch("success_rate") >= minimum_success_rate
          regressed = after.fetch("success_rate") < before.fetch("success_rate")
          failed_checks = after.fetch("check_failures").select { |_, count| count.positive? }.keys
          {
            "task_digest" => task.digest, "critical" => spec.fetch("critical"),
            "chain" => spec.fetch("chain"), "baseline" => before, "candidate" => after,
            "transition" => passed_before && !passed_after ? "pass_to_fail" :
                            (!passed_before && passed_after ? "fail_to_pass" : "unchanged"),
            "regressed" => regressed, "failed_checks" => failed_checks,
            "critical_failure" => spec.fetch("critical") && !passed_after,
            "quality_delta" => after.fetch("quality") - before.fetch("quality"),
            "cost_delta" => after.fetch("cost") - before.fetch("cost"),
            "latency_delta" => after.fetch("latency") - before.fetch("latency")
          }
        end
        regressions = rows.count { |row| row["regressed"] }
        critical = rows.select { |row| row["critical_failure"] }.map { |row| row["task_digest"] }
        failed_checks = rows.select { |row| row["failed_checks"].any? }.map { |row| row["task_digest"] }
        covered = coverage(tasks)
        reasons = []
        reasons << "critical_task_failed" if critical.any?
        reasons << "required_check_failed" if failed_checks.any?
        reasons << "regression_limit_exceeded" if max_regressions && regressions > max_regressions
        reasons << "uncovered_production_chain" unless covered["complete"]
        Harness.deep_freeze(
          "allowed" => reasons.empty?, "reasons" => reasons, "task_count" => rows.size,
          "regressions" => regressions, "pass_to_fail" => rows.count { |row| row["transition"] == "pass_to_fail" },
          "fail_to_pass" => rows.count { |row| row["transition"] == "fail_to_pass" },
          "critical_failures" => critical, "required_check_failures" => failed_checks,
          "coverage" => covered, "tasks" => rows
        )
      end

      def self.name!(value)
        unless value.is_a?(String) && value.match?(NAME)
          raise HarnessExperimentError, "architecture names must be bounded identifiers"
        end
        value
      end

      def self.chain!(value)
        unless value.is_a?(Array) && value.size.between?(1, MAX_CHAIN)
          raise HarnessExperimentError, "architecture chain must contain 1..#{MAX_CHAIN} names"
        end
        value.map { |name| name!(name) }
      end

      private

      def average(probes, key) = probes.sum { |probe| probe.fetch(key) }.to_f / probes.size
    end
  end
end
