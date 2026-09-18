# frozen_string_literal: true

module Agentkit
  class GraphEdgeRecord < ApplicationRecord
    self.table_name = "agentkit_graph_edges"

    belongs_to :snapshot, class_name: "Agentkit::GraphSnapshotRecord"
    validates :edge_id, :tenant_key, :from_node_id, :to_node_id, :edge_type,
              :direction, :source_digest, :lifecycle_status, presence: true
    validates :weight, numericality: { greater_than_or_equal_to: 0 }
    validates :confidence, numericality: { in: 0.0..1.0 }
    validate :matches_snapshot_scope

    private

    def matches_snapshot_scope
      return unless snapshot

      errors.add(:tenant_key, "does not match snapshot") if tenant_key.to_s != snapshot.tenant_key.to_s
    end
  end
end
