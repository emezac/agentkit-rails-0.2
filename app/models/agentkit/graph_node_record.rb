# frozen_string_literal: true

module Agentkit
  class GraphNodeRecord < ApplicationRecord
    self.table_name = "agentkit_graph_nodes"

    belongs_to :snapshot, class_name: "Agentkit::GraphSnapshotRecord"
    validates :node_id, :tenant_key, :asset_id, :node_type, :external_ref,
              :lifecycle_status, :visibility_digest, :content_digest, presence: true
    validate :matches_snapshot_scope

    private

    def matches_snapshot_scope
      return unless snapshot

      errors.add(:tenant_key, "does not match snapshot") if tenant_key.to_s != snapshot.tenant_key.to_s
      errors.add(:asset_id, "does not match snapshot") if asset_id.to_s != snapshot.asset_id.to_s
    end
  end
end
