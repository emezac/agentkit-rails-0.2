# frozen_string_literal: true

module Agentkit
  class FactoryDiagnoseJob < ApplicationJob
    queue_as :agentkit_factory

    def perform(window_days = 7, scope = nil)
      resolved = Agentkit::Scope.resolve(scope)
      Agentkit.with_context(Agentkit::Context.new(tenant_key: resolved.tenant_key)) do
        run = begin_factory_run(window_days, resolved)
        Agentkit::Factory.capture_golden!
        findings = Agentkit::Factory.diagnose!(window: window_days * 86_400)
        evaluated = act_for_mode(findings)
        finish_factory_run(run, "completed", experiments_evaluated: evaluated,
                                             **Agentkit::Factory.last_diagnosis)
        findings
      rescue StandardError => e
        finish_factory_run(run, "failed", errors: [{ class: e.class.name, message: e.message }]) if run
        raise
      end
    end

    private

    def act_for_mode(findings)
      case Agentkit.config.factory.mode
      when :observe
        return 0
      when :suggest
        Agentkit::Factory.suggest_interventions!(findings)
      when :auto_n1
        Agentkit::Factory.auto_start_interventions!(findings, max_level: :n1)
      when :auto_n1_n2
        Agentkit::Factory.auto_start_interventions!(findings, max_level: :n2)
      end

      running = Agentkit::Factory.experiments.select { |experiment| experiment.status == "running" }
      running.each { |experiment| Agentkit::Factory.evaluate(experiment) }
      running.size
    end

    def begin_factory_run(window_days, scope)
      return nil unless defined?(Agentkit::FactoryRunRecord) && Agentkit::FactoryRunRecord.table_exists?

      Agentkit::FactoryRunRecord.create!(window_days: window_days, started_at: Time.current,
                                         tenant_key: scope.tenant_key || "__global__",
                                         account_id: scope.account_id)
    end

    def finish_factory_run(run, status, **attributes)
      return unless run

      allowed = %i[detector_count fired_count created_count deduplicated_count
                   experiments_evaluated metadata]
      filtered = attributes.slice(*allowed)
      filtered[:error_details] = attributes[:errors] if attributes.key?(:errors)
      run.finish!(status: status, **filtered)
    end
  end
end
