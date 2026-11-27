# frozen_string_literal: true
require_relative "returns_reference"

module ReturnsReference
  class RefundDeliveryJob < ActiveJob::Base
    # Configure in trusted host boot code. Do not deserialize credentials or
    # accept a principal supplied by a browser/LLM as a worker identity.
    class_attribute :workflow_factory, :context_resolver

    def perform(intent_id, tenant_key, account_id)
      raise K::AccessDenied, "host job ports not configured" unless workflow_factory && context_resolver
      context = context_resolver.call(tenant_key, account_id)
      identity = K::Boundary.identity(context)
      unless identity.values_at("tenant", "account") == [tenant_key.to_s, account_id.to_s]
        raise K::AccessDenied, "worker scope mismatch"
      end
      workflow_factory.call.deliver(id: intent_id, context: context)
    end
  end
end
