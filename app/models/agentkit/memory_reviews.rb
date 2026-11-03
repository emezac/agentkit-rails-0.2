# frozen_string_literal: true

module Agentkit
  # A proposal is not searchable memory until a console-authorized reviewer
  # approves it. Every transition leaves an append-only journal entry.
  module MemoryReviews
    module_function

    def propose!(content:, tags: [], source_agent: nil, proposed_by: nil, context: nil)
      ctx = context || Agentkit::Context.resolve
      scope = Agentkit::Scope.resolve(context: ctx)
      proposal = Agentkit::MemoryProposalRecord.create!(
        tenant_key: scope.tenant_key || "__global__", account_id: scope.account_id,
        user_id: ctx.user.respond_to?(:id) ? ctx.user.id : nil,
        content: content, tags: Array(tags).map(&:to_s), source_agent: source_agent,
        proposed_by: proposed_by || ctx.principal
      )
      proposal.review_events.create!(event: "proposed", actor: proposal.proposed_by.presence || "system")
      proposal
    end

    def approve!(id, actor:, context: nil)
      ctx = context || Agentkit::Context.resolve
      proposal = scoped(context: ctx).find(id)
      proposal.with_lock do
        raise Agentkit::ConfigurationError, "proposal is not pending" unless proposal.status == "pending"

        memory_context = ctx.tenant_key.nil? ? ctx.derive(tenant_key: "__global__") : ctx
        memory = Agentkit::Memory.store(proposal.content, tags: proposal.tags,
                                        source_agent: proposal.source_agent,
                                        metadata: { review_proposal_id: proposal.id }, context: memory_context)
        raise Agentkit::ConfigurationError, "memory writes are disabled" if memory.nil?

        proposal.update!(status: "approved", memory_id: memory.id,
                         reviewed_by: actor, reviewed_at: Time.current)
        proposal.review_events.create!(event: "approved", actor: actor,
                                       details: { memory_id: memory.id })
        proposal
      end
    end

    def reject!(id, actor:, context: nil)
      proposal = scoped(context: context).find(id)
      proposal.with_lock do
        raise Agentkit::ConfigurationError, "proposal is not pending" unless proposal.status == "pending"

        proposal.update!(status: "rejected", reviewed_by: actor, reviewed_at: Time.current)
        proposal.review_events.create!(event: "rejected", actor: actor)
        proposal
      end
    end

    def undo!(id, actor:, context: nil)
      proposal = scoped(context: context).find(id)
      proposal.with_lock do
        raise Agentkit::ConfigurationError, "proposal is not approved" unless proposal.status == "approved"

        memory = Agentkit::MemoryRecord.where(id: proposal.memory_id,
                                             tenant_key: proposal.tenant_key,
                                             account_id: proposal.account_id).first!
        unless memory.metadata["review_proposal_id"].to_s == proposal.id.to_s
          raise Agentkit::ConfigurationError, "memory provenance does not match proposal"
        end
        memory.update!(status: "archived", archived_at: Time.current)
        proposal.update!(status: "undone", undone_at: Time.current)
        proposal.review_events.create!(event: "undone", actor: actor,
                                       details: { memory_id: memory.id })
        proposal
      end
    end

    def scoped(context: nil)
      scope = Agentkit::Scope.resolve(context: context || Agentkit::Context.resolve)
      Agentkit::MemoryProposalRecord.where(tenant_key: scope.tenant_key || "__global__",
                                           account_id: scope.account_id)
    end
  end
end
