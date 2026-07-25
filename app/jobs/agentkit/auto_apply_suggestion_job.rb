# frozen_string_literal: true

module Agentkit
  # Advisory mode auto-apply. Scheduled with `set(wait:).perform_later` — v0.1
  # called `perform_in`, a Sidekiq method ActiveJob does not have, and raised in
  # every project that enabled advisory mode.
  class AutoApplySuggestionJob < ApplicationJob
    queue_as :agentkit_hitl

    def perform(suggestion_id)
      suggestion = Agentkit::HITL.find(suggestion_id)
      return if suggestion.nil? || !suggestion.pending?

      # mode: "auto" keeps timeouts out of the acceptance rate.
      Agentkit::HITL.approve(suggestion_id, actor: "auto:timeout", mode: "auto")
    end
  end
end
