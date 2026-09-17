# frozen_string_literal: true

module Agentkit
  class ApplicationController < ActionController::Base
    layout "agentkit/application"

    protect_from_forgery with: :exception

    before_action :set_agentkit_security_headers
    before_action :require_agentkit_access!
    around_action :with_agentkit_scope

    # The factory view reads it to label the reporting period. Without this it
    # is a private controller method and the panel raises NameError on render —
    # the console was unreachable in any app that actually opened it.
    helper_method :window, :agentkit_payload

    private

    def with_agentkit_scope(&block)
      Agentkit.with_context(agentkit_context, &block)
    end

    def require_agentkit_access!
      return head(:not_found) unless Agentkit.config.console.enabled

      resolver = Agentkit.config.console.principal_resolver
      guard = Agentkit.config.console.guard
      return head(:forbidden) unless resolver.respond_to?(:call) && guard.respond_to?(:call)

      @agentkit_principal = instance_exec(&resolver)
      return head(:forbidden) if @agentkit_principal.nil?

      allowed = guard.arity.zero? ? instance_exec(&guard) : instance_exec(@agentkit_principal, &guard)
      return head(:forbidden) unless allowed

      @agentkit_account = send(:current_account) if respond_to?(:current_account, true)
      return head(:forbidden) if Agentkit.config.multi_tenant && @agentkit_account.nil?

      true
    rescue StandardError => e
      Agentkit.logger&.warn(
        "[AgentKit::Console] access denied request_id=#{request.request_id} error=#{e.class}"
      )
      head(:forbidden) unless performed?
    end

    def agentkit_context
      principal = @agentkit_principal
      Agentkit::Context.new(user: principal, account: @agentkit_account,
                            principal: principal_identifier(principal))
    end

    def actor
      "human:#{principal_identifier(@agentkit_principal)}"
    end

    def principal_identifier(principal)
      return principal.agentkit_principal if principal.respond_to?(:agentkit_principal)
      return "#{principal.class.name}:#{principal.id}" if principal.respond_to?(:id)

      principal.to_s
    end

    def set_agentkit_security_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Content-Security-Policy"] =
        "default-src 'self'; frame-ancestors 'none'; object-src 'none'; " \
        "base-uri 'self'; form-action 'self'; style-src 'self' 'unsafe-inline'"
      response.headers["Referrer-Policy"] = "no-referrer"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["X-Frame-Options"] = "DENY"
    end

    def agentkit_payload(payload)
      guard = Agentkit.config.console.payload_guard
      allowed = if guard.respond_to?(:call)
                  guard.arity.zero? ? instance_exec(&guard) : instance_exec(@agentkit_principal, &guard)
                else
                  false
                end
      allowed ? payload : Agentkit::Audit.sanitize_payload(payload)
    rescue StandardError => e
      Agentkit.logger&.warn(
        "[AgentKit::Console] payload redacted request_id=#{request.request_id} error=#{e.class}"
      )
      Agentkit::Audit.sanitize_payload(payload)
    end

    def window
      (params[:days].presence || 7).to_i * 86_400
    end
  end
end
