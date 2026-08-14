# frozen_string_literal: true

class CreateAgentkitKnowledge < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_knowledge_chunks do |t|
      t.string  :corpus_name,   null: false
      t.string  :chunk_id,      null: false
      t.integer :chapter_index
      t.string  :chapter_title
      t.text    :content,       null: false
      t.string  :source
      t.integer :chunk_index,   null: false, default: 0
      t.jsonb   :metadata,      null: false, default: {}
      t.jsonb   :bm25_doc_freq, null: false, default: {}
      t.timestamps
    end

    if vector_available?
      dims = 1536
      execute "ALTER TABLE agentkit_knowledge_chunks ADD COLUMN embedding vector(#{dims});"
    end

    execute <<~SQL
      ALTER TABLE agentkit_knowledge_chunks
      ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (to_tsvector('simple', coalesce(content, '')));
    SQL

    add_index :agentkit_knowledge_chunks, %i[corpus_name chunk_id], unique: true
    add_index :agentkit_knowledge_chunks, %i[corpus_name chapter_index]
    add_index :agentkit_knowledge_chunks, :search_vector, using: :gin
    add_index :agentkit_knowledge_chunks, :content, using: :gin, opclass: :gin_trgm_ops

    if vector_available?
      execute <<~SQL
        CREATE INDEX IF NOT EXISTS idx_agentkit_knowledge_embedding
        ON agentkit_knowledge_chunks USING hnsw (embedding vector_cosine_ops)
        WHERE embedding IS NOT NULL;
      SQL
    end
  end

  private

  def vector_available?
    return @vector_available unless @vector_available.nil?

    @vector_available =
      select_value("SELECT 1 FROM pg_available_extensions WHERE name = 'vector'").present? &&
      defined?(::Pgvector)
  end
end
