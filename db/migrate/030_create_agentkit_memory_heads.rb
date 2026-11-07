# frozen_string_literal: true

class CreateAgentkitMemoryHeads < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_memory_heads do |t|
      t.string :scope_key, :topic_key, null: false
      t.integer :revision, null: false, default: 0
      t.timestamps
    end
    add_index :agentkit_memory_heads, %i[scope_key topic_key], unique: true, name: "idx_agentkit_memory_head_identity"
    add_check_constraint :agentkit_memory_heads, "revision >= 0", name: "agentkit_memory_head_revision"
  end
end
