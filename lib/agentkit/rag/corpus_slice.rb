# frozen_string_literal: true

require "securerandom"

module Agentkit
  module RAG
    # Represents a partition of a document corpus (e.g., 1 chapter or 1 size batch).
    class CorpusSlice
      attr_accessor :slice_id, :corpus_name, :chapter_index, :title, :page_range, :byte_size, :chunks, :metadata

      def initialize(slice_id: nil, corpus_name: nil, chapter_index: nil, title: nil,
                     page_range: nil, byte_size: 0, chunks: [], metadata: {})
        @slice_id      = slice_id || SecureRandom.uuid
        @corpus_name   = corpus_name
        @chapter_index = chapter_index
        @title         = title || "Chapter #{chapter_index}"
        @page_range    = page_range
        @byte_size     = byte_size
        @chunks        = chunks || []
        @metadata      = metadata || {}
      end

      def to_h
        {
          "slice_id"      => slice_id,
          "corpus_name"   => corpus_name,
          "chapter_index" => chapter_index,
          "title"         => title,
          "page_range"    => page_range,
          "byte_size"     => byte_size,
          "chunks"        => chunks,
          "metadata"      => metadata
        }
      end

      def self.from_h(hash)
        return nil if hash.nil?
        return hash if hash.is_a?(CorpusSlice)

        h = hash.transform_keys(&:to_s)
        new(
          slice_id:      h["slice_id"],
          corpus_name:   h["corpus_name"],
          chapter_index: h["chapter_index"],
          title:         h["title"],
          page_range:    h["page_range"],
          byte_size:     h["byte_size"],
          chunks:        h["chunks"],
          metadata:      h["metadata"]
        )
      end
    end
  end
end
