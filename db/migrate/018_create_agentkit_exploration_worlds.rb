# frozen_string_literal: true

class CreateAgentkitExplorationWorlds < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_exploration_worlds do |t|
      t.string :world_id, null: false
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id
      t.string :objective_digest, null: false
      t.string :policy_name, null: false
      t.string :policy_version, null: false
      t.string :policy_digest, null: false
      t.string :evaluator_digest, null: false
      t.jsonb :bounds, null: false, default: {}
      t.jsonb :tree, null: false, default: {}
      t.integer :rounds, null: false, default: 0
      t.integer :node_count, null: false, default: 0
      t.decimal :best_score, precision: 20, scale: 8
      t.string :status, null: false
      t.string :stop_reason, null: false
      t.datetime :completed_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :agentkit_exploration_worlds, :world_id, unique: true
    add_index :agentkit_exploration_worlds, %i[tenant_key created_at],
              name: "idx_agentkit_exploration_worlds_scope"
    add_index :agentkit_exploration_worlds, %i[tenant_key policy_name policy_version],
              name: "idx_agentkit_exploration_worlds_policy"
    add_check_constraint :agentkit_exploration_worlds, "rounds >= 0 AND node_count >= 0",
                         name: "chk_agentkit_exploration_world_counts"
  end
end
