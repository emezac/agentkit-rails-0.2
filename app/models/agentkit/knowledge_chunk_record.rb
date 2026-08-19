# frozen_string_literal: true

module Agentkit
  class KnowledgeChunkRecord < ApplicationRecord
    self.table_name = "agentkit_knowledge_chunks"

    validates :tenant_key, presence: true
    validates :corpus_name, :chunk_id, :content, presence: true
    validates :chunk_id, uniqueness: { scope: %i[tenant_key corpus_name] }

    def to_hash
      {
        "id"            => chunk_id,
        "text"          => content,
        "source"        => source,
        "metadata"      => metadata,
        "chunk_index"   => chunk_index,
        "chapter_index" => chapter_index,
        "chapter_title" => chapter_title,
        "corpus_name"   => corpus_name,
        "tenant_key"    => tenant_key,
        "account_id"    => account_id
      }
    end
  end
end
