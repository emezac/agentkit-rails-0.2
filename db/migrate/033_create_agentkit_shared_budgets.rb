# frozen_string_literal: true
class CreateAgentkitSharedBudgets < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_shared_budgets do |t|
      t.string :tenant_key, :budget_key, :contract_digest, null: false
      t.jsonb :contract, :usage, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_shared_budgets, %i[tenant_key budget_key], unique: true, name: "idx_agentkit_shared_budget_identity"
    create_table :agentkit_budget_reservations do |t|
      t.references :shared_budget, null: false, foreign_key: { to_table: :agentkit_shared_budgets }
      t.string :reservation_key, :request_digest, :status, null: false
      t.jsonb :request, null: false, default: {}
      t.jsonb :settlement
      t.timestamps
    end
    add_index :agentkit_budget_reservations, %i[shared_budget_id reservation_key], unique: true, name: "idx_agentkit_budget_reservation_identity"
  end
end
