class CreateAgentkitOperatorWorkflows < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_routines do |t|
      t.string :tenant_key, :flow_name, :name, :schedule_kind, :time_zone, null: false
      t.bigint :account_id, :user_id
      t.jsonb :input, null: false, default: {}
      t.string :status, null: false, default: "active"
      t.integer :interval_seconds, :hour, :minute
      t.datetime :next_run_at, :last_run_at
      t.timestamps
    end
    add_index :agentkit_routines, %i[status next_run_at]
    add_index :agentkit_routines, %i[tenant_key account_id]
    add_check_constraint :agentkit_routines, "status IN ('active', 'paused')", name: "agentkit_routines_status"
    add_check_constraint :agentkit_routines, "schedule_kind IN ('once', 'interval', 'daily')", name: "agentkit_routines_schedule"

    create_table :agentkit_routine_occurrences do |t|
      t.references :routine, null: false, foreign_key: { to_table: :agentkit_routines }
      t.string :tenant_key, null: false
      t.bigint :account_id
      t.datetime :scheduled_for, null: false
      t.string :status, null: false, default: "pending"
      t.string :flow_run_id
      t.text :error
      t.timestamps
    end
    add_index :agentkit_routine_occurrences, %i[routine_id scheduled_for], unique: true, name: "idx_agentkit_routine_occurrence"
    add_index :agentkit_routine_occurrences, %i[tenant_key account_id status], name: "idx_agentkit_routine_attention"
    add_check_constraint :agentkit_routine_occurrences, "status IN ('pending', 'dispatching', 'dispatched', 'failed')", name: "agentkit_routine_occurrence_status"

    create_table :agentkit_memory_proposals do |t|
      t.string :tenant_key, null: false
      t.bigint :account_id, :user_id, :memory_id
      t.text :content, null: false
      t.jsonb :tags, null: false, default: []
      t.string :source_agent
      t.string :status, null: false, default: "pending"
      t.string :proposed_by, :reviewed_by
      t.datetime :reviewed_at, :undone_at
      t.timestamps
    end
    add_index :agentkit_memory_proposals, %i[tenant_key account_id status], name: "idx_agentkit_memory_proposals_scope"
    add_check_constraint :agentkit_memory_proposals, "status IN ('pending', 'approved', 'rejected', 'undone')", name: "agentkit_memory_proposal_status"

    create_table :agentkit_memory_review_events do |t|
      t.references :proposal, null: false, foreign_key: { to_table: :agentkit_memory_proposals }
      t.string :event, :actor, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_memory_review_events, %i[proposal_id created_at]
  end
end
