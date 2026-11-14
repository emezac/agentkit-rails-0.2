# frozen_string_literal: true

class CreateAgentkitUnattendedRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_unattended_runs do |t|
      t.string :scope_key, :run_key, :contract_digest, null: false
      t.jsonb :contract, :runtime, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_unattended_runs, %i[scope_key run_key], unique: true, name: "idx_agentkit_unattended_identity"
  end
end
