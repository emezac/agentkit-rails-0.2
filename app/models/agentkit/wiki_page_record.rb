# frozen_string_literal: true

module Agentkit
  class WikiPageRecord < ApplicationRecord
    self.table_name = "agentkit_wiki_pages"

    belongs_to :asset, class_name: "Agentkit::MemoryAssetRecord"

    validates :title, presence: true
    validates :content, presence: true
    validates :tenant_key, presence: true

    def to_h
      {
        "id"         => id,
        "asset_id"   => asset_id,
        "title"      => title,
        "content"    => content,
        "links"      => links,
        "status"     => status,
        "created_at" => created_at
      }
    end
  end
end
