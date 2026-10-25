# frozen_string_literal: true

class CreateAgentkitKnowledgeEntries < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_knowledge_entries do |t|
      t.string :scope_key, null: false
      t.string :tenant_key, null: false
      t.string :account_key, null: false
      t.string :kind, null: false
      t.string :entry_key, null: false
      t.string :request_digest, null: false
      t.string :payload_digest, null: false
      t.string :state, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_knowledge_entries, %i[scope_key kind entry_key], unique: true,
              name: "idx_agentkit_knowledge_entry_identity"
    add_column :agentkit_action_proposals, :knowledge_gate_digest, :string
  end
end
