# frozen_string_literal: true

class CreateAgentkitOperationsEscalations < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_operations_escalations do |t|
      t.string :scope_key, :entry_key, :request_digest, null: false
      t.jsonb :payload, null: false
      t.string :status, null: false, default: "open"
      t.integer :target_index, :attempts, null: false, default: 0
      t.datetime :ack_due_at, :next_attempt_at, null: false
      t.string :lease_token, :acknowledged_by
      t.datetime :lease_until, :delivered_at, :acknowledged_at
      t.timestamps
    end
    add_index :agentkit_operations_escalations, %i[scope_key entry_key], unique: true, name: "idx_agentkit_ops_identity"
    add_index :agentkit_operations_escalations, %i[scope_key status next_attempt_at], name: "idx_agentkit_ops_due"
    add_check_constraint :agentkit_operations_escalations, "status IN ('open', 'acknowledged', 'exhausted')", name: "agentkit_ops_status"
  end
end
