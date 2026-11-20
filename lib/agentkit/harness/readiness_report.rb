# frozen_string_literal: true

module Agentkit
  module Harness
    # Deterministic preflight for a harness run. It inspects contracts and
    # references only; it never invokes a model, verifier, tool or side effect.
    class ReadinessReport
      REQUIREMENTS = %i[budget context verifier rollback].freeze

      Report = Struct.new(:ready, :checks, :blockers, :warnings, :generated_at, :digest,
                          keyword_init: true) do
        def ready? = !!ready

        def to_h
          {
            ready: ready?, checks: checks, blockers: blockers, warnings: warnings,
            generated_at: generated_at, digest: digest
          }
        end
      end

      class << self
        def build(progress:, tools: [], budget: nil, context_sources: [], verifier: nil,
                  rollback_reference: nil, required: [])
          unless progress.is_a?(Progress)
            raise ArgumentError, "progress must be an Agentkit::Harness::Progress"
          end

          requirements = Array(required).map(&:to_sym).uniq
          unknown = requirements - REQUIREMENTS
          raise ArgumentError, "unknown readiness requirements: #{unknown.join(', ')}" if unknown.any?

          checks = []
          check_progress(checks, progress)
          contracts = check_tools(checks, tools)
          check_budget(checks, budget, required: requirements.include?(:budget))
          check_context(checks, context_sources, required: requirements.include?(:context))
          check_verifier(checks, verifier, required: requirements.include?(:verifier))
          check_rollback(checks, rollback_reference, required: requirements.include?(:rollback))
          check_protected_resources(checks, progress, verifier)
          check_side_effect_contracts(checks, contracts)

          blockers = checks.select { |item| item[:status] == "failed" }.map { |item| item[:id] }
          warnings = checks.select { |item| item[:status] == "warning" }.map { |item| item[:id] }
          generated_at = Time.now.utc.iso8601(6)
          payload = { ready: blockers.empty?, checks: checks, blockers: blockers, warnings: warnings,
                      generated_at: generated_at }
          Report.new(**payload, digest: Harness.digest(payload)).tap do |report|
            Harness.deep_freeze(report.checks)
            Harness.deep_freeze(report.blockers)
            Harness.deep_freeze(report.warnings)
            report.freeze
          end
        end

        private

        def check_progress(checks, progress)
          evaluation = progress.evaluate
          if progress.status == "failed"
            add(checks, :progress, :failed, "progress is already failed")
          elsif progress.step_count >= progress.goal.max_steps && !evaluation.complete?
            add(checks, :progress, :failed, "step budget is exhausted")
          else
            add(checks, :progress, :passed, "goal contract and step bounds are valid")
          end
        end

        def check_tools(checks, tools)
          contracts = Array(tools)
          invalid = contracts.reject { |tool| tool.is_a?(ToolContract) }
          duplicate_names = contracts.select { |tool| tool.is_a?(ToolContract) }
                                     .group_by { |tool| tool.name.to_s }
                                     .select { |_, values| values.size > 1 }.keys
          if invalid.any?
            add(checks, :tool_contracts, :failed, "all tools must be ToolContract instances")
          elsif duplicate_names.any?
            add(checks, :tool_contracts, :failed, "tool names must be unique")
          else
            contracts.each(&:contract_digest)
            add(checks, :tool_contracts, :passed, "#{contracts.size} immutable contracts inspected")
          end
          contracts.select { |tool| tool.is_a?(ToolContract) }
        end

        def check_budget(checks, budget, required:)
          if budget.nil?
            add(checks, :execution_budget, required ? :failed : :warning, "no execution budget supplied")
            return
          end

          snapshot = budget.is_a?(ExecutionBudget) ? budget.snapshot : Harness.stringify_keys(budget)
          limits = snapshot[:limits] || snapshot["limits"] || {}
          limits = Harness.stringify_keys(limits)
          valid = limits["max_turns"].to_i.positive? && limits["max_tokens"].to_i.positive?
          add(checks, :execution_budget, valid ? :passed : :failed,
              valid ? "turn and token limits are positive" : "budget needs positive turn and token limits")
        rescue StandardError
          add(checks, :execution_budget, :failed, "budget is not inspectable")
        end

        def check_context(checks, context_sources, required:)
          sources = context_sources.respond_to?(:evidence) ? context_sources.evidence : Array(context_sources)
          if sources.empty?
            add(checks, :context_provenance, required ? :failed : :warning, "no context source receipts supplied")
            return
          end

          invalid = sources.any? do |source|
            data = Harness.stringify_keys(source.respond_to?(:to_h) ? source.to_h : source)
            reference = data["reference"] || data["name"] || data["source_id"]
            reference.to_s.strip.empty? || !valid_digest?(data["digest"])
          rescue StandardError
            true
          end
          add(checks, :context_provenance, invalid ? :failed : :passed,
              invalid ? "context receipts need a reference and digest" : "#{sources.size} source receipts are traceable")
        end

        def check_verifier(checks, verifier, required:)
          if verifier.nil?
            add(checks, :independent_verifier, required ? :failed : :warning, "no independent verifier supplied")
          elsif verifier.is_a?(Verifier) || verifier.respond_to?(:call)
            add(checks, :independent_verifier, :passed, "verifier boundary is available")
          else
            add(checks, :independent_verifier, :failed, "verifier must be Harness::Verifier or callable")
          end
        end

        def check_rollback(checks, reference, required:)
          if reference.to_s.strip.empty?
            add(checks, :rollback_reference, required ? :failed : :warning, "no rollback reference supplied")
          else
            add(checks, :rollback_reference, :passed, "rollback reference is declared")
          end
        end

        def check_protected_resources(checks, progress, verifier)
          goal = progress.goal
          guarded = goal.protected_resources.empty? || goal.required_approvals.any? || !verifier.nil?
          add(checks, :protected_resources, guarded ? :passed : :failed,
              guarded ? "protected resources have an explicit guard" : "protected resources need approval or verification")
        end

        def check_side_effect_contracts(checks, contracts)
          effects = contracts.reject(&:read_only?)
          if effects.empty?
            add(checks, :side_effect_boundary, :passed, "all direct tools are read-only")
          else
            add(checks, :side_effect_boundary, :warning,
                "#{effects.size} effectful contracts must remain routed through Actions")
          end
        end

        def add(checks, id, status, detail)
          checks << { id: id.to_s, status: status.to_s, detail: detail }.freeze
        end

        def valid_digest?(value)
          Harness.valid_digest!(value)
          true
        rescue ArgumentError
          false
        end
      end
    end
  end
end
