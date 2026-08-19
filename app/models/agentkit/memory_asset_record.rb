# frozen_string_literal: true

module Agentkit
  class MemoryAssetRecord < ApplicationRecord
    self.table_name = "agentkit_memory_assets"

    belongs_to :team, class_name: "Agentkit::TeamRecord", optional: true
    has_many :wiki_pages, class_name: "Agentkit::WikiPageRecord", foreign_key: "asset_id", dependent: :destroy
    has_many :code_symbols, class_name: "Agentkit::CodeSymbolRecord", foreign_key: "asset_id", dependent: :destroy
    has_many :asset_bindings, class_name: "Agentkit::AssetBindingRecord", foreign_key: "asset_id", dependent: :destroy

    ASSET_TYPES  = %w[chat_memory skill wiki code_graph].freeze
    VISIBILITIES = %w[private team restricted agent public].freeze

    validates :asset_type, presence: true, inclusion: { in: ASSET_TYPES }
    validates :tenant_key, presence: true
    validates :name, presence: true
    validates :visibility, inclusion: { in: VISIBILITIES }

    def to_h
      {
        "id"          => id,
        "team_id"     => team_id,
        "asset_type"  => asset_type,
        "name"        => name,
        "visibility"  => visibility,
        "owner_id"    => owner_id,
        "version"     => version,
        "status"      => status,
        "usage_count" => usage_count,
        "content"     => content,
        "bindings"    => bindings,
        "created_at"  => created_at,
        "tenant_key"  => tenant_key,
        "account_id"  => account_id
      }
    end
  end
end
