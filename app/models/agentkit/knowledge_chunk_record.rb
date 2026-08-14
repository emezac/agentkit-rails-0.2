# frozen_string_literal: true

module Agentkit
  class KnowledgeChunkRecord < ApplicationRecord
    self.table_name = "agentkit_knowledge_chunks"

    def to_hash
      {
        "id"            => chunk_id,
        "text"          => content,
        "source"        => source,
        "metadata"      => metadata,
        "chunk_index"   => chunk_index,
        "chapter_index" => chapter_index,
        "chapter_title" => chapter_title,
        "corpus_name"   => corpus_name
      }
    end
  end
end
