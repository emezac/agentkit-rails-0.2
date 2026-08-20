# frozen_string_literal: true

module Agentkit
  # Explicit resource boundary passed to every durable lookup. It deliberately
  # does not rely on a worker's ambient thread-local context.
  class Scope
    attr_reader :tenant_key, :account_id, :principal

    def initialize(tenant_key: nil, account_id: nil, principal: nil)
      @tenant_key = tenant_key
      @account_id = account_id
      @principal = principal
      validate!
    end

    def self.resolve(value = nil, context: Context.resolve)
      return value.tap(&:validate!) if value.is_a?(self)

      attrs = value || {}
      requested_tenant = attrs[:tenant_key] || attrs["tenant_key"]
      if context.tenant_key && requested_tenant && context.tenant_key.to_s != requested_tenant.to_s
        raise ConfigurationError, "AgentKit scope cannot cross the current tenant boundary"
      end
      new(
        tenant_key: context.tenant_key || requested_tenant,
        account_id: attrs[:account_id] || attrs["account_id"] || id_of(context.account),
        principal: attrs[:principal] || attrs["principal"] || context.principal
      )
    end

    def validate!
      if Agentkit.config.multi_tenant && tenant_key.to_s.empty?
        raise ConfigurationError, "AgentKit scope requires a tenant_key when multi_tenant is enabled"
      end
      self
    end

    def to_h = { tenant_key: tenant_key, account_id: account_id, principal: principal }.compact

    def apply(filters = {})
      filters.to_h.merge({ tenant_key: tenant_key, account_id: account_id }.compact)
    end

    def match?(resource)
      return false if resource.nil?
      return true if tenant_key.nil? && account_id.nil?
      return false if tenant_key && field(resource, :tenant_key).to_s != tenant_key.to_s
      return false if account_id && field(resource, :account_id).to_s != account_id.to_s

      true
    end

    class << self
      private

      def id_of(object) = object.respond_to?(:id) ? object.id : object
    end

    private

    def field(resource, key)
      resource.respond_to?(key) ? resource.public_send(key) : resource[key] || resource[key.to_s]
    end
  end
end
