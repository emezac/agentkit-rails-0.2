# frozen_string_literal: true

class AddMemoryLifecycle < ActiveRecord::Migration[7.1]
  def change
    add_column :agentkit_memories, :retention_policy, :string,
               null: false, default: "keep"
    add_column :agentkit_memories, :pinned_at, :datetime
    add_column :agentkit_memories, :archived_at, :datetime

    add_index :agentkit_memories, %i[tenant_key retention_policy]
    add_index :agentkit_memories, %i[tenant_key pinned_at],
              where: "pinned_at IS NOT NULL",
              name: "idx_agentkit_memories_pinned"
    add_index :agentkit_memories, %i[tenant_key expires_at],
              where: "expires_at IS NOT NULL AND status IN ('raw','embedded','consolidated')",
              name: "idx_agentkit_memories_expiration"
  end
end
