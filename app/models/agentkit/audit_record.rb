# frozen_string_literal: true

module Agentkit
  # Immutable audit trail. Successor of v0.1's Agentkit::AgentLog, with
  # correlation ids so an entry can be joined to the run, the step and the
  # cognitive trace that produced it.
  class AuditRecord < ApplicationRecord
    self.table_name = "agentkit_audit_logs"

    belongs_to :subject, polymorphic: true, optional: true

    scope :for_agent, ->(name) { where(agent_name: name) }
    scope :of_type,   ->(type) { where(event_type: type) }
    scope :since,     ->(t) { where(occurred_at: t..) }
    scope :for_trace, ->(id) { where(trace_id: id) }
    scope :for_run,   ->(id) { where(run_id: id) }
    scope :failed,    -> { where(status: %w[failed error]) }

    # Append-only by contract. Retention is a deliberate, separate operation.
    before_update  { raise ActiveRecord::ReadOnlyRecord, "audit rows are immutable" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "use Audit.prune! for retention" }

    def self.total_cost_usd(scope = all) = scope.sum(:cost_usd).to_f.round(6)
    def self.avg_duration_ms(scope = all) = scope.average(:duration_ms)&.round(1)
  end
end
