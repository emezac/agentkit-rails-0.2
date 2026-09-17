# frozen_string_literal: true

class CreateAgentkitGovernedActions < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_action_proposals do |t|
      t.string :public_id, null: false
      t.string :tenant_key, null: false, default: "__global__"
      t.string :action_type, null: false
      t.jsonb :arguments, null: false, default: {}
      t.string :arguments_digest, null: false
      t.string :requester_principal_id, null: false
      t.string :required_permission
      t.string :target_type
      t.string :target_id
      t.string :risk, null: false
      t.string :effect, null: false
      t.string :policy_version, null: false
      t.string :contract_version, null: false
      t.string :status, null: false, default: "draft"
      t.string :operation_namespace, null: false
      t.string :idempotency_key
      t.string :source_adapter
      t.jsonb :canonical_response
      t.datetime :expires_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :agentkit_action_proposals, :public_id, unique: true
    add_index :agentkit_action_proposals, %i[tenant_key status updated_at], name: "idx_agentkit_actions_lifecycle"
    add_index :agentkit_action_proposals,
              %i[tenant_key operation_namespace idempotency_key],
              unique: true, where: "idempotency_key IS NOT NULL",
              name: "idx_agentkit_actions_durable_idempotency"

    create_table :agentkit_action_decisions do |t|
      t.references :proposal, null: false, index: false,
                   foreign_key: { to_table: :agentkit_action_proposals }
      t.string :tenant_key, null: false, default: "__global__"
      t.string :decision, null: false
      t.string :actor_principal_id, null: false
      t.datetime :decided_at, null: false
      t.string :approved_arguments_digest
      t.string :policy_version, null: false
      t.string :reason_code
      t.timestamps
    end
    add_index :agentkit_action_decisions, :proposal_id, unique: true
    add_index :agentkit_action_decisions, %i[tenant_key decided_at]

    create_table :agentkit_execution_attempts do |t|
      t.references :proposal, null: false, index: false,
                   foreign_key: { to_table: :agentkit_action_proposals }
      t.string :tenant_key, null: false, default: "__global__"
      t.integer :attempt_number, null: false
      t.string :idempotency_key, null: false
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :error_code
      t.string :external_result_ref
      t.jsonb :canonical_response
      t.timestamps
    end
    add_index :agentkit_execution_attempts, %i[proposal_id attempt_number], unique: true,
              name: "idx_agentkit_execution_attempt_number"
    add_index :agentkit_execution_attempts, %i[tenant_key status started_at],
              name: "idx_agentkit_execution_lifecycle"

    create_table :agentkit_action_outboxes do |t|
      t.references :proposal, null: false, index: false,
                   foreign_key: { to_table: :agentkit_action_proposals }
      t.string :tenant_key, null: false, default: "__global__"
      t.string :event_type, null: false, default: "action.execute"
      t.string :status, null: false, default: "pending"
      t.integer :delivery_attempts, null: false, default: 0
      t.datetime :dispatched_at
      t.string :last_error_code
      t.timestamps
    end
    add_index :agentkit_action_outboxes, :proposal_id, unique: true
    add_index :agentkit_action_outboxes, %i[status created_at]

    create_table :agentkit_action_outcomes do |t|
      t.references :proposal, null: false, foreign_key: { to_table: :agentkit_action_proposals }
      t.string :tenant_key, null: false, default: "__global__"
      t.string :kind, null: false
      t.datetime :observed_at, null: false
      t.jsonb :value
      t.string :evidence_digest, null: false
      t.string :source, null: false
      t.float :confidence
      t.timestamps
    end
    add_index :agentkit_action_outcomes, %i[proposal_id observed_at]

    create_table :agentkit_audit_chain_heads do |t|
      t.string :tenant_key, null: false
      t.bigint :sequence, null: false, default: 0
      t.string :last_hash
      t.timestamps
    end
    add_index :agentkit_audit_chain_heads, :tenant_key, unique: true

    change_table :agentkit_audit_logs do |t|
      t.integer :schema_version, null: false, default: 1
      t.bigint :sequence
      t.string :principal_id
      t.string :payload_digest
      t.string :previous_hash
      t.string :event_hash
      t.string :signature
      t.string :key_id
    end
    add_index :agentkit_audit_logs, %i[tenant_key sequence], unique: true,
              where: "schema_version = 2", name: "idx_agentkit_audit_chain_sequence"
    add_index :agentkit_audit_logs, :event_hash, unique: true,
              where: "event_hash IS NOT NULL", name: "idx_agentkit_audit_event_hash"

    create_table :agentkit_watchtower_issues do |t|
      t.string :tenant_key, null: false, default: "__global__"
      t.string :fingerprint, null: false
      t.string :detector, null: false
      t.string :severity, null: false
      t.string :status, null: false, default: "open"
      t.string :subject_type
      t.string :subject_id
      t.jsonb :evidence, null: false, default: {}
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :agentkit_watchtower_issues, %i[tenant_key fingerprint], unique: true,
              name: "idx_agentkit_watchtower_fingerprint"
    add_index :agentkit_watchtower_issues, %i[tenant_key status severity],
              name: "idx_agentkit_watchtower_status"
  end
end
