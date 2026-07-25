# frozen_string_literal: true

module Agentkit
  class TraceRecord < ApplicationRecord
    self.table_name = "agentkit_traces"

    has_many :phases, class_name: "Agentkit::TracePhaseRecord",
                      foreign_key: :trace_id, dependent: :destroy, inverse_of: :trace

    scope :of_kind, ->(k) { where(kind: k.to_s) }
    scope :recent,  -> { order(started_at: :desc) }

    # Everything the trace produced or consumed, for the XAI console.
    def audit_entries = Agentkit::AuditRecord.for_trace(trace_id)

    def to_timeline
      phases.order(:position).map { |p| { name: p.name, at: p.occurred_at, **p.data } }
    end
  end
end
