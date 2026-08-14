# frozen_string_literal: true

module Agentkit
  class AssetBindingRecord < ApplicationRecord
    self.table_name = "agentkit_asset_bindings"

    belongs_to :asset, class_name: "Agentkit::MemoryAssetRecord"

    validates :agent_name, presence: true

    def to_h
      {
        "id"          => id,
        "asset_id"    => asset_id,
        "agent_name"  => agent_name,
        "target_type" => target_type,
        "target_id"   => target_id,
        "priority"    => priority,
        "created_at"  => created_at
      }
    end
  end
end
