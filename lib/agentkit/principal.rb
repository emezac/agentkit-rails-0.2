# frozen_string_literal: true

module Agentkit
  # Transport-neutral authenticated identity. Adapters may derive it from a
  # session, bearer token, API gateway or mTLS certificate, but model-supplied
  # arguments can never create or modify it.
  class Principal
    attr_reader :id, :tenant_key, :permissions, :source, :metadata

    def initialize(id:, tenant_key: nil, permissions: [], source: nil, metadata: {})
      raise ConfigurationError, "principal id is required" if id.to_s.empty?

      @id = id.to_s
      @tenant_key = tenant_key&.to_s
      @permissions = Array(permissions).map(&:to_s).freeze
      @source = source&.to_s
      @metadata = (metadata || {}).freeze
      freeze
    end

    def allowed?(permission)
      return true if permission.to_s.empty?

      permissions.include?(permission.to_s) || permissions.include?("*")
    end

    def to_s = id

    def self.coerce(value, tenant_key: nil, permissions: nil, source: nil)
      return value if value.is_a?(self)
      return nil if value.nil? || value.to_s.empty?

      identifier = if value.respond_to?(:agentkit_principal)
                     value.agentkit_principal
                   elsif value.respond_to?(:id)
                     "#{value.class.name}:#{value.id}"
                   else
                     value.to_s
                   end
      new(id: identifier,
          tenant_key: tenant_key,
          permissions: permissions || inferred_permissions(value), source: source)
    end

    def self.inferred_permissions(value)
      value.respond_to?(:agentkit_permissions) ? value.agentkit_permissions : []
    end
    private_class_method :inferred_permissions
  end
end
