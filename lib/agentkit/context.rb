# frozen_string_literal: true

require "securerandom"

module Agentkit
  # Explicit execution context. Replaces v0.1's `attr_accessor :current_user`
  # on the agent instance, which forced every caller to thread the user by hand
  # and broke outright for hosts without a User model (MaaS authenticates with
  # API keys; `tres` has no user at all).
  #
  # Everything here is optional. A context with only an account is valid.
  #
  #   ctx = Agentkit::Context.new(account: tenant, tenant_key: "acme")
  #   Agentkit.with_context(ctx) { MyAgent.new.call(record) }
  #
  #   Agentkit::Context.current   # => ctx (thread-local, fiber-safe)
  class Context
    attr_reader :user, :account, :tenant_key, :run_id, :trace_id, :metadata, :parent
    attr_accessor :budget

    def initialize(user: nil, account: nil, tenant_key: nil, run_id: nil, trace_id: nil,
                   budget: nil, config: nil, metadata: {}, parent: nil)
      @user       = user
      @account    = account
      @tenant_key = tenant_key || derive_tenant_key(account)
      @run_id     = run_id   || SecureRandom.uuid
      @trace_id   = trace_id || @run_id
      @budget     = budget
      @config     = config
      @metadata   = metadata || {}
      @parent     = parent
    end

    # Effective configuration for this context, with per-tenant overrides applied
    # once and memoized.
    def config
      @config ||= Agentkit.config.for_tenant(account)
    end

    # Derive a child context (sub-flows, fan-out branches) keeping correlation.
    def derive(**overrides)
      self.class.new(
        user:       overrides.fetch(:user, user),
        account:    overrides.fetch(:account, account),
        tenant_key: overrides.fetch(:tenant_key, tenant_key),
        run_id:     overrides.fetch(:run_id, SecureRandom.uuid),
        trace_id:   overrides.fetch(:trace_id, trace_id),
        budget:     overrides.fetch(:budget, budget),
        config:     overrides.fetch(:config, @config),
        metadata:   metadata.merge(overrides.fetch(:metadata, {})),
        parent:     self
      )
    end

    # Dimensions attached to every telemetry event emitted under this context.
    def telemetry_dims
      {
        tenant:   tenant_key,
        user_id:  user.respond_to?(:id) ? user.id : user,
        run_id:   run_id
      }.compact
    end

    def to_h
      {
        user_id:    user.respond_to?(:id) ? user.id : user,
        account_id: account.respond_to?(:id) ? account.id : account,
        tenant_key: tenant_key,
        run_id:     run_id,
        trace_id:   trace_id,
        metadata:   metadata
      }.compact
    end

    # ─── Thread-local current context ────────────────────────────────────────

    KEY = :agentkit_context

    class << self
      def current
        Thread.current[KEY]
      end

      def current=(ctx)
        Thread.current[KEY] = ctx
      end

      # Always returns a context — anonymous if none is active. Kernel code uses
      # this so it never has to nil-check.
      def resolve
        current || new
      end

      def with(ctx)
        previous = current
        self.current = ctx
        yield ctx
      ensure
        self.current = previous
      end
    end

    private

    def derive_tenant_key(account)
      return nil if account.nil?
      return account.tenant_key if account.respond_to?(:tenant_key)
      return "account:#{account.id}" if account.respond_to?(:id)

      account.to_s
    end
  end
end
