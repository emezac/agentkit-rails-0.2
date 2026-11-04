class AddRedactedAtToAgentkitTaskEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :agentkit_task_events, :redacted_at, :datetime
  end
end
