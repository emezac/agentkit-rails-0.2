# frozen_string_literal: true

class HardenAgentkitExploration < ActiveRecord::Migration[7.1]
  def change
    change_column_null :agentkit_exploration_worlds, :completed_at, true
    change_column_null :agentkit_exploration_worlds, :stop_reason, true
    add_column :agentkit_exploration_worlds, :checkpoint_version, :integer,
               null: false, default: 0
    add_column :agentkit_exploration_worlds, :last_checkpoint_at, :datetime
    add_column :agentkit_exploration_worlds, :evaluator_manifest, :jsonb,
               null: false, default: {}
    create_table :agentkit_exploration_attempts do |t|
      t.string :attempt_id, null: false
      t.string :world_id, null: false
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id
      t.integer :round_number, null: false
      t.integer :position, null: false
      t.string :parent_node_id, null: false
      t.string :idempotency_key, null: false
      t.string :status, null: false, default: "pending"
      t.string :outcome_status
      t.string :node_id
      t.decimal :score, precision: 20, scale: 8
      t.string :artifact_digest
      t.string :failure_class
      t.jsonb :diagnostics, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :agentkit_exploration_attempts, :attempt_id, unique: true
    add_index :agentkit_exploration_attempts,
              %i[tenant_key world_id round_number position], unique: true,
              name: "idx_agentkit_exploration_attempts_slot"
    add_index :agentkit_exploration_attempts,
              %i[tenant_key idempotency_key], unique: true,
              name: "idx_agentkit_exploration_attempts_idempotency"
    add_index :agentkit_exploration_attempts,
              %i[tenant_key status updated_at],
              name: "idx_agentkit_exploration_attempts_status"
    add_check_constraint :agentkit_exploration_attempts,
                         "round_number >= 0 AND position >= 0",
                         name: "chk_agentkit_exploration_attempt_counts"
  end
end
