# frozen_string_literal: true

module Agentkit
  class CodeSymbolRecord < ApplicationRecord
    self.table_name = "agentkit_code_symbols"

    belongs_to :asset, class_name: "Agentkit::MemoryAssetRecord"

    SYMBOL_TYPES = %w[class method module function constant].freeze

    validates :name, presence: true
    validates :tenant_key, presence: true
    validates :file_path, presence: true
    validates :symbol_type, presence: true, inclusion: { in: SYMBOL_TYPES }

    def to_h
      {
        "id"          => id,
        "asset_id"    => asset_id,
        "name"        => name,
        "qualified_name" => respond_to?(:qualified_name) ? qualified_name : name,
        "symbol_type" => symbol_type,
        "file_path"   => file_path,
        "line_number" => line_number,
        "callers"     => callers,
        "callees"     => callees,
        "file_digest" => respond_to?(:file_digest) ? file_digest : nil,
        "provenance" => respond_to?(:provenance) ? provenance : {},
        "confidence" => respond_to?(:confidence) ? confidence : 1.0,
        "created_at"  => created_at
      }
    end
  end
end
