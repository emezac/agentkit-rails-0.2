# frozen_string_literal: true

module Agentkit
  module RAG
    # Chunking strategies for document text.
    class Chunker
      def initialize(chunk_size: 256, chunk_overlap: 50, strategy: :sliding_window)
        @chunk_size = chunk_size
        @chunk_overlap = chunk_overlap
        @strategy = strategy
      end

      attr_reader :chunk_size, :chunk_overlap, :strategy

      def chunk_documents(documents)
        chunks = []
        step = [1, chunk_size - chunk_overlap].max

        documents.each do |doc|
          text = d_field(doc, :text) || d_field(doc, :content) || ""
          doc_id = d_field(doc, :id) || "doc"
          source = d_field(doc, :source) || ""
          metadata = d_field(doc, :metadata) || {}
          chapter_index = d_field(doc, :chapter_index)
          chapter_title = d_field(doc, :chapter_title)

          words = text.split
          if words.size <= chunk_size
            chunks << build_chunk_hash(doc_id, text, source, metadata, doc_id, 0, chapter_index, chapter_title)
            next
          end

          (0...words.size).step(step).each_with_index do |start, chunk_idx|
            chunk_words = words[start, chunk_size] || []
            break if chunk_words.empty?

            chunk_text = chunk_words.join(" ")
            c_id = "#{doc_id}_c#{chunk_idx}"
            chunks << build_chunk_hash(c_id, chunk_text, source, metadata, doc_id, chunk_idx, chapter_index, chapter_title)
          end
        end

        chunks
      end

      private

      def d_field(doc, key)
        doc.is_a?(Hash) ? (doc[key.to_s] || doc[key.to_sym]) : nil
      end

      def build_chunk_hash(id, text, source, metadata, parent_id, idx, chapter_index, chapter_title)
        {
          "id"            => id,
          "text"          => text,
          "source"        => source,
          "metadata"      => metadata,
          "parent_id"     => parent_id,
          "chunk_index"   => idx,
          "chapter_index" => chapter_index,
          "chapter_title" => chapter_title
        }.compact
      end
    end
  end
end
