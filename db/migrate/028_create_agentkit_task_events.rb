class CreateAgentkitTaskEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_task_threads do |t|
      t.string :tenant_key, :account_key, :source, :resource, :thread, :run_id, null: false
      t.bigint :account_id
      t.timestamps
    end
    add_index :agentkit_task_threads, %i[tenant_key account_key source resource thread],
              unique: true, name: "idx_agentkit_task_thread_identity"
    add_index :agentkit_task_threads, %i[tenant_key account_key run_id], name: "idx_agentkit_task_thread_run"

    create_table :agentkit_task_events do |t|
      t.references :task_thread, null: false, foreign_key: { to_table: :agentkit_task_threads }
      t.string :event_key, :payload_digest, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :agentkit_task_events, %i[task_thread_id event_key], unique: true,
              name: "idx_agentkit_task_event_identity"
    add_index :agentkit_task_events, %i[task_thread_id consumed_at], name: "idx_agentkit_task_event_pending"
  end
end
