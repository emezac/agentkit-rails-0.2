# frozen_string_literal: true

module Agentkit
  module RAG
    # Splitting documents or PDFs into chapter-level CorpusSlices.
    class ChapterChunker
      HEADING_REGEX = /^(?:chapter|cap[ií]tulo|section|parte|secci[oó]n|\#\#|\#)\s+([0-9ivxlcdm]+|\w+)/i

      def initialize(strategy: :heading_regex, max_slice_mb: 10, heading_pattern: nil)
        @strategy = strategy
        @max_slice_mb = max_slice_mb
        @heading_pattern = heading_pattern || HEADING_REGEX
      end

      attr_reader :strategy, :max_slice_mb, :heading_pattern

      def split(documents, corpus_name: "default_corpus")
        docs = Array(documents).map { |d| d.is_a?(Hash) ? d : { "text" => d.to_s } }
        return [] if docs.empty?

        case strategy
        when :heading_regex, :bookmark
          split_by_headings(docs, corpus_name)
        when :page_budget
          split_by_page_budget(docs, corpus_name, pages_per_slice: 10)
        when :size_budget
          split_by_size_budget(docs, corpus_name, max_bytes: max_slice_mb * 1024 * 1024)
        else
          split_by_headings(docs, corpus_name)
        end
      end

      private

      def split_by_headings(docs, corpus_name)
        slices = []
        current_title = "Introduction / Preface"
        current_docs = []
        chapter_idx = 0

        docs.each do |doc|
          text = (doc["text"] || doc[:text]).to_s
          lines = text.lines.map(&:strip)
          heading = lines.find { |l| l =~ heading_pattern }

          if heading && current_docs.any?
            chapter_idx += 1
            slices << build_slice(corpus_name, chapter_idx, current_title, current_docs)
            current_title = heading
            current_docs = [doc]
          else
            current_title = heading if heading && current_docs.empty?
            current_docs << doc
          end
        end

        if current_docs.any?
          chapter_idx += 1
          slices << build_slice(corpus_name, chapter_idx, current_title, current_docs)
        end

        slices
      end

      def split_by_page_budget(docs, corpus_name, pages_per_slice: 10)
        slices = []
        docs.each_slice(pages_per_slice).with_index(1) do |batch, idx|
          title = "Chapter #{idx} (Pages #{batch.first['metadata']&.fetch('page', nil) || 'N/A'}-#{batch.last['metadata']&.fetch('page', nil) || 'N/A'})"
          slices << build_slice(corpus_name, idx, title, batch)
        end
        slices
      end

      def split_by_size_budget(docs, corpus_name, max_bytes: 10_485_760)
        slices = []
        current_batch = []
        current_bytes = 0
        chapter_idx = 1

        docs.each do |doc|
          text_bytes = (doc["text"] || doc[:text]).to_s.bytesize
          if current_bytes + text_bytes > max_bytes && current_batch.any?
            slices << build_slice(corpus_name, chapter_idx, "Part #{chapter_idx}", current_batch)
            chapter_idx += 1
            current_batch = [doc]
            current_bytes = text_bytes
          else
            current_batch << doc
            current_bytes += text_bytes
          end
        end

        if current_batch.any?
          slices << build_slice(corpus_name, chapter_idx, "Part #{chapter_idx}", current_batch)
        end

        slices
      end

      def build_slice(corpus_name, chapter_idx, title, docs)
        total_bytes = docs.sum { |d| (d["text"] || d[:text]).to_s.bytesize }
        pages = docs.map { |d| d.dig("metadata", "page") || d.dig(:metadata, :page) }.compact
        page_range = pages.any? ? [pages.min, pages.max] : nil

        CorpusSlice.new(
          corpus_name: corpus_name,
          chapter_index: chapter_idx,
          title: title,
          page_range: page_range,
          byte_size: total_bytes,
          chunks: docs,
          metadata: { "doc_count" => docs.size }
        )
      end
    end
  end
end
