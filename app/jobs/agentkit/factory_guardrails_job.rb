# frozen_string_literal: true

module Agentkit
  # Guardrails run frequently and independently from weekly promotion. A bad
  # canary must not remain live for days merely because diagnosis is weekly.
  class FactoryGuardrailsJob < ApplicationJob
    queue_as :agentkit_factory

    def perform
      Agentkit::Factory.experiments
                       .select { |experiment| experiment.status == "running" }
                       .each { |experiment| Agentkit::Factory.enforce_guardrails!(experiment) }
    end
  end
end
