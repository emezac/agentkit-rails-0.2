# frozen_string_literal: true

class AddDistributedExplorationAndQuotas < ActiveRecord::Migration[7.1]
  def change
    add_column :agentkit_exploration_worlds, :generator_digest, :string
    add_column :agentkit_exploration_worlds, :generator_manifest, :jsonb,
               null: false, default: {}
    add_index :agentkit_exploration_worlds, %i[tenant_key status created_at],
              name: "idx_agentkit_exploration_worlds_operations"

    create_table :agentkit_exploration_quota_usages do |t|
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id, null: false, default: 0
      t.string :resource, null: false
      t.date :period_start, null: false
      t.integer :used, null: false, default: 0
      t.timestamps
    end
    add_index :agentkit_exploration_quota_usages,
              %i[tenant_key account_id resource period_start], unique: true,
              name: "idx_agentkit_exploration_quota_usage"
    add_check_constraint :agentkit_exploration_quota_usages, "used >= 0",
                         name: "chk_agentkit_exploration_quota_used"

    create_table :agentkit_exploration_quota_reservations do |t|
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id, null: false, default: 0
      t.string :resource, null: false
      t.string :reservation_key, null: false
      t.integer :amount, null: false
      t.date :period_start, null: false
      t.timestamps
    end
    add_index :agentkit_exploration_quota_reservations,
              %i[tenant_key account_id resource reservation_key], unique: true,
              name: "idx_agentkit_exploration_quota_reservation"
    add_index :agentkit_exploration_quota_reservations,
              %i[tenant_key period_start resource],
              name: "idx_agentkit_exploration_quota_period"
    add_check_constraint :agentkit_exploration_quota_reservations, "amount > 0",
                         name: "chk_agentkit_exploration_quota_amount"
  end
end
