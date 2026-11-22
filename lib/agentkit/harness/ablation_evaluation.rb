# frozen_string_literal: true

module Agentkit
  module Harness
    # Opt-in harness ablation & decay evaluation contract.
    #
    # Generates leave-one-out removal candidates against an immutable base
    # Manifest and checks non-inferiority on quality, cost and latency so
    # obsolete or model-superseded components can be retired through the same
    # holdout and human-review governance as additive revisions.
    class AblationEvaluation
      SCHEMA_VERSION = 1

      attr_reader :max_quality_drop, :max_cost_increase, :max_latency_increase,
                  :protected_components, :previous_model_digest

      def initialize(max_quality_drop: 0.0, max_cost_increase: 0.0,
                     max_latency_increase: 0.0, protected_components: [],
                     previous_model_digest: nil)
        @max_quality_drop = non_negative_float!(max_quality_drop, "max_quality_drop")
        @max_cost_increase = non_negative_float!(max_cost_increase, "max_cost_increase")
        @max_latency_increase = non_negative_float!(max_latency_increase, "max_latency_increase")
        @protected_components = Array(protected_components).map { |entry| entry.to_s.strip }.reject(&:empty?).uniq.freeze
        @previous_model_digest = previous_model_digest && Harness.valid_digest!(previous_model_digest).freeze
        freeze
      end

      def to_h
        {
          "schema_version" => SCHEMA_VERSION,
          "max_quality_drop" => max_quality_drop,
          "max_cost_increase" => max_cost_increase,
          "max_latency_increase" => max_latency_increase,
          "protected_components" => protected_components,
          "previous_model_digest" => previous_model_digest
        }.compact
      end

      def digest = Harness.digest(to_h)

      def protected?(component, goal: nil)
        return true if protected_components.include?(component.key) || protected_components.include?(component.type)
        return false unless goal

        protected_resources = Array(goal.protected_resources)
        component.resources.any? do |resource|
          protected_resources.any? { |pattern| resource_match?(pattern, resource) }
        end
      end

      # Generates one declarative leave-one-out removal Revision per eligible
      # component in `base`. Skips protected components and any component
      # referenced as a dependency by another component in the manifest.
      def generate_revisions(base:, goal: nil, scope: "domain",
                             rationale: "Ablate potentially redundant harness component")
        manifest = base.is_a?(Manifest) ? base : Manifest.from_h(base)
        depended_on = manifest.components.flat_map(&:dependencies).uniq
        eligible = manifest.components.reject do |component|
          protected?(component, goal: goal) || depended_on.include?(component.key) || depended_on.include?(component.name)
        end

        eligible.map do |component|
          safe_id = "ablate_#{component.type}_#{component.name}".gsub(/[^a-zA-Z0-9_.-]/, "_")
          Revision.new(
            id: safe_id,
            base_digest: manifest.digest,
            scope: scope,
            changes: [
              Change.new(
                id: "remove-#{safe_id}",
                operation: "remove",
                target: component.key,
                rationale: "#{rationale}: #{component.key}"
              )
            ],
            rationale: "#{rationale}: #{component.key}",
            metadata: {
              "ablation" => true,
              "removed_component" => component.key
            }
          )
        end.freeze
      end

      def compare(incumbent:, candidate:, base_manifest:, candidate_manifest:, tasks: [], goal: nil)
        base_keys = base_manifest.components.map(&:key)
        candidate_keys = candidate_manifest.components.map(&:key)
        removed_keys = base_keys - candidate_keys
        added_keys = candidate_keys - base_keys
        removed_components = base_manifest.components.select { |c| removed_keys.include?(c.key) }

        quality_delta = (candidate.mean_quality - incumbent.mean_quality).round(6)
        cost_delta = (candidate.mean_cost - incumbent.mean_cost).round(6)
        latency_delta = (candidate.mean_latency - incumbent.mean_latency).round(6)
        bytes_saved = base_manifest.components.sum(&:context_bytes) - candidate_manifest.components.sum(&:context_bytes)
        model_digests = Array(tasks).map(&:model_digest).uniq.sort

        reasons = []
        reasons << "no_components_removed" if removed_keys.empty?
        reasons << "ablation_added_components" if added_keys.any?
        if removed_components.any? { |c| protected?(c, goal: goal) }
          reasons << "protected_component_removed"
        end
        reasons << "quality_regression" if quality_delta < -max_quality_drop
        reasons << "cost_regression" if cost_delta > max_cost_increase
        reasons << "latency_regression" if latency_delta > max_latency_increase

        report = {
          "schema_version" => SCHEMA_VERSION,
          "allowed" => reasons.empty?,
          "reasons" => reasons,
          "components_removed" => removed_keys,
          "context_bytes_saved" => bytes_saved,
          "quality_delta" => quality_delta,
          "cost_delta" => cost_delta,
          "latency_delta" => latency_delta,
          "model_digests" => model_digests
        }
        if previous_model_digest
          report["previous_model_digest"] = previous_model_digest
          report["model_changed"] = model_digests.any? { |d| d != previous_model_digest }
        end
        Harness.deep_freeze(report)
      end

      private

      def non_negative_float!(value, label)
        number = Float(value)
        raise HarnessExperimentError, "#{label} must be finite and >= 0" unless number.finite? && number >= 0.0

        number
      rescue ArgumentError, TypeError
        raise HarnessExperimentError, "#{label} must be numeric"
      end

      def resource_match?(pattern, resource)
        pat = pattern.to_s
        res = resource.to_s
        pat == res || (pat.end_with?("/") && res.start_with?(pat)) || File.fnmatch?(pat, res)
      end
    end
  end
end
