# frozen_string_literal: true

class CreateAgentkitBusinessExperiments < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_business_experiments do |t|
      t.string :scope_key, null: false
      t.string :experiment_key, null: false
      t.string :definition_digest, null: false
      t.jsonb :definition, null: false, default: {}
      t.string :status, null: false, default: "draft"
      t.jsonb :runtime, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_business_experiments, %i[scope_key experiment_key], unique: true,
              name: "idx_agentkit_business_experiment_identity"
    add_check_constraint :agentkit_business_experiments,
                         "status IN ('draft', 'approved', 'stopped', 'analyzed')",
                         name: "agentkit_business_experiment_status"
  end
end
