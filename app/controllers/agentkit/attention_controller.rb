# frozen_string_literal: true

module Agentkit
  class AttentionController < ApplicationController
    def index
      scope = Agentkit::Scope.resolve(context: agentkit_context)
      tenant = scope.tenant_key || "__global__"
      filters = { tenant_key: tenant, account_id: scope.account_id }
      @suggestions = Agentkit::SuggestionRecord.where(tenant_key: scope.tenant_key,
                                                      account_id: scope.account_id,
                                                      status: %w[pending snoozed])
                                                .order(created_at: :desc).limit(20)
      @runs = Agentkit::RunRecord.where(filters, status: %w[failed waiting_human timed_out])
                                .order(updated_at: :desc).limit(20)
      @routine_occurrences = Agentkit::RoutineOccurrenceRecord
                             .where(filters)
                             .where("status = 'failed' OR (status = 'dispatching' AND updated_at < ?)", 5.minutes.ago)
                             .order(updated_at: :desc).limit(20)
      @memory_proposals = Agentkit::MemoryProposalRecord.where(filters, status: "pending")
                                                        .order(created_at: :desc).limit(20)
      @escalations = if scope.tenant_key
                       key = Agentkit::Knowledge::Boundary.scope(agentkit_context)
                       Agentkit::OperationsEscalationRecord.where(scope_key: key, status: %w[open exhausted])
                                                           .order(updated_at: :desc).limit(20)
                     else
                       Agentkit::OperationsEscalationRecord.none
                     end
      render template: "agentkit/attention_index"
    end
  end
end
