# frozen_string_literal: true

class CreateAgentkitA2aTasks < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_a2a_tasks do |t|
      t.string :tenant_key, null: false, default: "__global__"
      t.string :task_id, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end

    add_index :agentkit_a2a_tasks, %i[tenant_key task_id], unique: true,
              name: "idx_agentkit_a2a_tasks_tenant_id"
    add_index :agentkit_a2a_tasks, %i[tenant_key created_at]
  end
end
