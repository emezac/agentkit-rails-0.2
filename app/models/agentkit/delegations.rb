# frozen_string_literal: true

module Agentkit
  # Durable asynchronous Flow hand-off. The Flow graph still owns budgets,
  # policy and human gates; this API only gives callers a scoped receipt.
  module Delegations
    Receipt = Struct.new(:run_id, :flow_name, :status, :output, :error, keyword_init: true)
    module_function

    def dispatch!(flow:, input:, context: nil, mandate: nil)
      ctx = context || Agentkit::Context.resolve
      Agentkit::Scope.resolve(context: ctx)
      raise Agentkit::ConfigurationError, "delegation requires a principal" if ctx.principal.to_s.empty?
      raise ArgumentError, "input must be a Hash" unless input.is_a?(Hash)

      klass = flow.is_a?(Class) ? flow : Agentkit::Flow::Registry.find(flow.to_s)
      raise Agentkit::FlowError, "delegation target must be a registered Flow" unless klass.is_a?(Class) && klass <= Agentkit::Flow && Agentkit::Flow::Registry.all.include?(klass)

      if mandate
        raise Agentkit::PolicyDenied, "a host-issued mandate is required" unless mandate.is_a?(TaskMandate)
        unless mandate.flow == klass.name && mandate.requester == ctx.principal.to_s &&
               mandate.tenant_key == ctx.tenant_key && mandate.account_id == (ctx.account.respond_to?(:id) ? ctx.account.id : ctx.account)
          raise Agentkit::PolicyDenied, "mandate does not match delegation"
        end
        ctx = ctx.derive(metadata: { task_mandate: mandate.to_h })
      end

      run = Agentkit.with_context(ctx) { klass.perform_later(context: ctx.derive, **input.symbolize_keys) }
      Receipt.new(run_id: run.run_id, flow_name: run.flow_name, status: run.status)
    end

    def receipt(run_id, context: nil)
      scope = Agentkit::Scope.resolve(context: context || Agentkit::Context.resolve)
      row = Agentkit::RunRecord.where(run_id: run_id,
                                      tenant_key: scope.tenant_key || "__global__",
                                      account_id: scope.account_id).first
      return nil unless row

      Receipt.new(run_id: row.run_id, flow_name: row.flow_name,
                  status: row.status, output: row.output, error: row.error)
    end
  end
end
