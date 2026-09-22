# frozen_string_literal: true

class AddExplorationPromotionGovernance < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_exploration_reviews do |t|
      t.string :dossier_id, null: false
      t.string :target, null: false
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.string :incumbent_name, null: false
      t.string :incumbent_version, null: false
      t.string :incumbent_digest, null: false
      t.string :candidate_name, null: false
      t.string :candidate_version, null: false
      t.string :candidate_digest, null: false
      t.string :evidence_digest, null: false
      t.jsonb :evidence, null: false, default: {}
      t.jsonb :previous_binding, null: false, default: {}
      t.string :reviewed_by
      t.text :review_reason
      t.datetime :submitted_at, null: false
      t.datetime :decided_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :agentkit_exploration_reviews, :dossier_id, unique: true
    add_index :agentkit_exploration_reviews,
              %i[tenant_key account_id target evidence_digest], unique: true,
              name: "idx_agentkit_exploration_review_evidence"
    add_index :agentkit_exploration_reviews,
              %i[tenant_key account_id status submitted_at],
              name: "idx_agentkit_exploration_review_queue"
    add_check_constraint :agentkit_exploration_reviews,
                         "status IN ('pending','approved','rejected','rolled_back')",
                         name: "chk_agentkit_exploration_review_status"

    create_table :agentkit_exploration_policy_bindings do |t|
      t.string :target, null: false
      t.string :tenant_key, null: false, default: "__global__"
      t.bigint :account_id, null: false, default: 0
      t.string :policy_name, null: false
      t.string :policy_version, null: false
      t.string :policy_digest, null: false
      t.string :dossier_id, null: false
      t.integer :generation, null: false, default: 1
      t.datetime :applied_at, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :agentkit_exploration_policy_bindings,
              %i[tenant_key account_id target], unique: true,
              name: "idx_agentkit_exploration_policy_binding"
    add_check_constraint :agentkit_exploration_policy_bindings, "generation > 0",
                         name: "chk_agentkit_exploration_binding_generation"
  end
end
