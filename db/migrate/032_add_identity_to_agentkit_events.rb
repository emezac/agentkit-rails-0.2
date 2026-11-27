# frozen_string_literal: true

class AddIdentityToAgentkitEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :agentkit_events, :event_id, :string
    add_index :agentkit_events, :event_id, unique: true
  end
end
