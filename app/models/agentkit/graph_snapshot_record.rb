# frozen_string_literal: true

module Agentkit
  class GraphSnapshotRecord < ApplicationRecord
    self.table_name = "agentkit_graph_snapshots"

    belongs_to :asset, class_name: "Agentkit::MemoryAssetRecord"
    has_many :graph_nodes, class_name: "Agentkit::GraphNodeRecord", foreign_key: "snapshot_id", dependent: :destroy
    has_many :graph_edges, class_name: "Agentkit::GraphEdgeRecord", foreign_key: "snapshot_id", dependent: :destroy

    validates :snapshot_id, :tenant_key, :digest, :status, presence: true
  end
end
