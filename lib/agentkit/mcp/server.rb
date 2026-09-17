# frozen_string_literal: true

module Agentkit
  module MCP
    # Builds official SDK tool classes from the explicit registry. Authentication
    # is supplied by the trusted transport context, never by model arguments.
    class Server
      TrustedContext = Struct.new(:principal, :context, :idempotency_key, keyword_init: true)

      attr_reader :registry, :name, :version

      def initialize(registry:, name: "agentkit", version: Agentkit::VERSION)
        @registry = registry
        @name = name
        @version = version
      end

      def sdk_server(principal: nil, context: nil, idempotency_key: nil)
        trusted = TrustedContext.new(principal: principal, context: context,
                                     idempotency_key: idempotency_key)
        ::MCP::Server.new(name: name, version: version,
                          tools: registry.tools.values.map { |tool| tool_class(tool) },
                          server_context: trusted)
      end

      def transport(stateless: true, principal:, context: nil, idempotency_key: nil,
                    max_request_bytes: 64 * 1024, **options)
        server = sdk_server(principal: principal, context: context,
                            idempotency_key: idempotency_key)
        ::MCP::Server::Transports::StreamableHTTPTransport.new(
          server, stateless: stateless, max_request_bytes: max_request_bytes, **options
        )
      end

      private

      def tool_class(tool)
        owner = self
        Class.new(::MCP::Tool) do
          tool_name tool.name
          description tool.capability.description.to_s
          input_schema tool.input_schema

          define_singleton_method(:call) do |server_context:, **arguments|
            result = owner.registry.call(
              tool.name, arguments: arguments, principal: server_context.principal,
              context: server_context.context,
              idempotency_key: server_context.idempotency_key
            )
            ::MCP::Tool::Response.new([
              { type: "text", text: JSON.generate(result) }
            ])
          end
        end
      end
    end

    # Rack boundary for size/rate/auth checks. It authenticates from headers
    # before touching rack.input, then delegates protocol parsing to the SDK.
    class RackApp
      def initialize(app, authenticator:, max_body_bytes: 64 * 1024,
                     rate_limiter: nil, timeout: 30)
        @app = app
        @authenticator = authenticator
        @max_body_bytes = max_body_bytes
        @rate_limiter = rate_limiter
        @timeout = timeout
      end

      def call(env)
        principal = @authenticator.call(env)
        return response(401, "unauthorized") unless principal
        return response(413, "request too large") if env.fetch("CONTENT_LENGTH", "0").to_i > @max_body_bytes
        return response(429, "rate limit exceeded") if @rate_limiter && !@rate_limiter.call(principal, env)

        env["agentkit.mcp.principal"] = principal
        Timeout.timeout(@timeout) do
          @app.respond_to?(:arity) && @app.arity != 1 ? @app.call(principal, env) : @app.call(env)
        end
      rescue Timeout::Error
        response(504, "timeout")
      end

      private

      def response(status, message)
        [status, { "content-type" => "application/json" },
         [JSON.generate(error: message)]]
      end
    end
  end
end
