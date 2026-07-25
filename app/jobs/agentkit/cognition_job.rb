# frozen_string_literal: true

module Agentkit
  # Cron is just one of four ways to invoke a processor; HTTP, CLI and flow
  # steps hit the same entry point.
  class CognitionJob < ApplicationJob
    queue_as :agentkit_cognition

    def perform(processor, scope = {}, options = {})
      Agentkit::Cognition.run(processor.to_sym, trigger: :cron,
                                                scope: scope.symbolize_keys,
                                                **options.symbolize_keys)
    end
  end
end
