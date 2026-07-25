# frozen_string_literal: true

module Agentkit
  class FactoryDiagnoseJob < ApplicationJob
    queue_as :agentkit_factory

    def perform(window_days = 7)
      Agentkit::Factory.capture_golden!
      findings = Agentkit::Factory.diagnose!(window: window_days * 86_400)

      # In :observe mode nothing acts on the findings — they only accumulate.
      return findings unless %i[auto_n1 auto_n1_n2].include?(Agentkit.config.factory.mode)

      Agentkit::Factory.experiments.select { |e| e.status == "running" }.each do |exp|
        Agentkit::Factory.enforce_guardrails!(exp)
        Agentkit::Factory.evaluate(exp)
      end
      findings
    end
  end
end
