# frozen_string_literal: true

module Agentkit
  # One policy decision shared by local calls, A2A and MCP. Transport adapters
  # ask this service; they never reinterpret risk or caller permissions.
  module Policy
    Decision = Struct.new(:effect, :reason, :policy_version, keyword_init: true) do
      def permit? = effect.to_sym == :execute
      def propose? = effect.to_sym == :propose
      def deny? = effect.to_sym == :deny
    end

    VERSION = "agentkit.policy.v1"

    class << self
      def resolve(capability:, principal:, mode:, context: Context.resolve)
        actor = Principal.coerce(principal, tenant_key: context.tenant_key)
        return decision(:deny, :missing_principal) unless actor
        return decision(:deny, :tenant_mismatch) if actor.tenant_key && context.tenant_key &&
                                                    actor.tenant_key != context.tenant_key.to_s
        return decision(:deny, :missing_permission) unless actor.allowed?(capability.required_permission)

        if (adapter = Agentkit.config.actions.policy)
          custom = adapter.call(capability: capability, principal: actor,
                                mode: mode.to_sym, context: context)
          return normalize(custom) if custom
        end

        requested = mode.to_sym
        return decision(:propose, :adapter_requested_proposal) if requested == :propose
        return decision(:deny, :privileged_not_explicitly_allowed) if capability.risk == :privileged
        return decision(:propose, :human_authorization_required) if capability.risk == :irreversible
        return decision(:deny, :sensitive_requires_explicit_policy) if capability.risk == :sensitive

        decision(:execute, :default_permit)
      end

      private

      def normalize(value)
        return value if value.is_a?(Decision)
        return decision(value, :custom_policy) if %i[execute propose deny].include?(value.to_sym)

        raise ConfigurationError, "action policy must return :execute, :propose, :deny or Policy::Decision"
      end

      def decision(effect, reason)
        Decision.new(effect: effect, reason: reason, policy_version: VERSION)
      end
    end
  end
end
