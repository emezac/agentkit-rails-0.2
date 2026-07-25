# frozen_string_literal: true

module Agentkit
  # Runs a triggered agent or flow asynchronously.
  #
  # For destroy triggers the record no longer exists, so the caller passes an
  # attribute snapshot instead of an id. v0.1 always passed an id and then
  # swallowed the resulting RecordNotFound, so destroy triggers never ran.
  class TriggerJob < ApplicationJob
    queue_as :agentkit_agents

    retry_on Agentkit::TransientError, wait: :polynomially_longer, attempts: 3
    discard_on ActiveRecord::RecordNotFound

    def perform(kind, target_name, record_class_name, record_id, snapshot = nil, user_id = nil)
      target  = target_name.constantize
      record  = snapshot || record_class_name.constantize.find(record_id)
      context = Agentkit::Context.new(user: user_id && resolve_user(user_id))

      if kind.to_s == "flow"
        target.call(context: context, record: record)
      else
        target.call(record, context: context)
      end
    end

    private

    # The kernel never assumes a User constant — v0.1's worker hardcoded it and
    # broke on API-key hosts.
    def resolve_user(id)
      return nil unless Object.const_defined?(:User)

      Object.const_get(:User).find_by(id: id)
    end
  end
end
