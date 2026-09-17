# frozen_string_literal: true

require "agentkit"

begin
  require "mcp"
rescue LoadError => e
  raise Agentkit::ConfigurationError,
        "agentkit-mcp requires the official `mcp` gem (~> 1.5): #{e.message}"
end

require_relative "mcp/registry"
require_relative "mcp/server"

module Agentkit
  module MCP
    class Configuration
      attr_accessor :enabled, :authenticator, :principal_resolver, :rate_limiter,
                    :max_body_bytes, :timeout

      def initialize
        @enabled = false
        @max_body_bytes = 64 * 1024
        @timeout = 30
      end
    end

    class << self
      def configuration = @configuration ||= Configuration.new
      def registry = @registry ||= Registry.new

      def configure
        yield self
        validate!
        self
      end

      def expose(capability, **options) = registry.expose(capability, **options)

      def enabled=(value)
        configuration.enabled = value
      end

      def authenticator=(value)
        configuration.authenticator = value
      end

      def principal_resolver=(value)
        configuration.principal_resolver = value
      end

      def rate_limiter=(value)
        configuration.rate_limiter = value
      end

      def max_body_bytes=(value)
        configuration.max_body_bytes = Integer(value)
      end

      def timeout=(value)
        configuration.timeout = Integer(value)
      end

      def validate!
        return true unless configuration.enabled
        unless configuration.authenticator.respond_to?(:call) &&
               configuration.principal_resolver.respond_to?(:call)
          raise Agentkit::ConfigurationError,
                "MCP requires authenticator and principal_resolver when enabled"
        end
        true
      end

      def rack_app(server: Server.new(registry: registry), **transport_options)
        validate!
        authenticate = lambda do |env|
          credential = configuration.authenticator.call(env)
          next nil if credential.nil?

          resolver = configuration.principal_resolver
          resolver.arity == 1 ? resolver.call(credential) : resolver.call(credential, env)
        end
        delegate = lambda do |principal, env|
          actor = Principal.coerce(principal, source: :mcp)
          context = Context.new(tenant_key: actor.tenant_key, principal: actor,
                                metadata: { via: "mcp" })
          server.transport(principal: actor, context: context,
                           idempotency_key: env["HTTP_IDEMPOTENCY_KEY"],
                           max_request_bytes: configuration.max_body_bytes,
                           **transport_options).call(env)
        end
        RackApp.new(delegate, authenticator: authenticate,
                    max_body_bytes: configuration.max_body_bytes,
                    rate_limiter: configuration.rate_limiter,
                    timeout: configuration.timeout)
      end

      def reset!
        @configuration = Configuration.new
        @registry = Registry.new
      end
    end
  end
end
