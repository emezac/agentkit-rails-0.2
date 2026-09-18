# frozen_string_literal: true

class CreateAgentkitGraphSnapshots < ActiveRecord::Migration[7.1]
  def change
    add_column :agentkit_code_symbols, :qualified_name, :string unless column_exists?(:agentkit_code_symbols, :qualified_name)
    add_column :agentkit_code_symbols, :file_digest, :string unless column_exists?(:agentkit_code_symbols, :file_digest)
    add_column :agentkit_code_symbols, :provenance, :jsonb, null: false, default: {} unless column_exists?(:agentkit_code_symbols, :provenance)
    add_column :agentkit_code_symbols, :confidence, :decimal, precision: 5, scale: 4, null: false, default: 1.0 unless column_exists?(:agentkit_code_symbols, :confidence)

    create_table :agentkit_graph_snapshots do |t|
      t.string :snapshot_id, null: false
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id
      t.references :asset, null: false, foreign_key: { to_table: :agentkit_memory_assets }
      t.integer :schema_version, null: false, default: 1
      t.datetime :generated_at, null: false
      t.integer :node_count, null: false, default: 0
      t.integer :edge_count, null: false, default: 0
      t.string :digest, null: false
      t.string :status, null: false, default: "validated"
      t.jsonb :diagnostics, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_graph_snapshots, :snapshot_id, unique: true
    add_index :agentkit_graph_snapshots, %i[tenant_key asset_id status],
              name: "idx_agentkit_graph_snapshots_scope"
    add_index :agentkit_graph_snapshots, %i[tenant_key asset_id digest], unique: true,
              name: "idx_agentkit_graph_snapshots_digest"

    create_table :agentkit_graph_nodes do |t|
      t.references :snapshot, null: false, foreign_key: { to_table: :agentkit_graph_snapshots }
      t.string :node_id, null: false
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id
      t.bigint :asset_id, null: false
      t.string :node_type, null: false
      t.string :external_ref, null: false
      t.string :label
      t.string :lifecycle_status, null: false, default: "active"
      t.string :visibility_digest, null: false
      t.string :content_digest, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_graph_nodes, %i[snapshot_id node_id], unique: true,
              name: "idx_agentkit_graph_nodes_identity"
    add_index :agentkit_graph_nodes, %i[tenant_key asset_id external_ref],
              name: "idx_agentkit_graph_nodes_scope_ref"

    create_table :agentkit_graph_edges do |t|
      t.references :snapshot, null: false, foreign_key: { to_table: :agentkit_graph_snapshots }
      t.string :edge_id, null: false
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id
      t.string :from_node_id, null: false
      t.string :to_node_id, null: false
      t.string :edge_type, null: false
      t.string :direction, null: false, default: "outbound"
      t.decimal :weight, precision: 12, scale: 8, null: false, default: 1.0
      t.string :source_digest, null: false
      t.decimal :confidence, precision: 5, scale: 4, null: false, default: 1.0
      t.string :lifecycle_status, null: false, default: "active"
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_graph_edges, %i[snapshot_id edge_id], unique: true,
              name: "idx_agentkit_graph_edges_identity"
    add_index :agentkit_graph_edges, %i[snapshot_id from_node_id to_node_id],
              name: "idx_agentkit_graph_edges_path"
    add_index :agentkit_graph_edges, :tenant_key
    add_check_constraint :agentkit_graph_edges, "weight >= 0 AND weight <= 1000",
                         name: "chk_agentkit_graph_edge_weight"
    add_check_constraint :agentkit_graph_edges, "confidence >= 0 AND confidence <= 1",
                         name: "chk_agentkit_graph_edge_confidence"
  end
end
