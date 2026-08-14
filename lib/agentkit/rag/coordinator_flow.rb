# frozen_string_literal: true

module Agentkit
  module RAG
    # Chunking agent for PDF/Text documents by chapters/headings.
    class PDFChapterChunkerAgent < Agent
      def call(input)
        pdf_text     = input[:pdf_text] || input["pdf_text"]
        pdf_path     = input[:pdf_path] || input["pdf_path"]
        corpus_name  = input[:corpus_name] || input["corpus_name"]
        strategy     = (input[:strategy] || input["strategy"] || :heading_regex).to_sym
        max_slice_mb = input[:max_slice_mb] || input["max_slice_mb"] || 10

        docs = if pdf_path && File.exist?(pdf_path)
                 Corpus.from_pdf(pdf_path)
               elsif pdf_text
                 pdf_text.split("\n\n").map { |t| { "text" => t } }
               else
                 []
               end

        chunker = ChapterChunker.new(strategy: strategy, max_slice_mb: max_slice_mb)
        slices  = chunker.split(docs, corpus_name: corpus_name)

        Result.ok({
          slices:         slices.map(&:to_h),
          total_chapters: slices.size
        })
      end
    end

    # Parallel indexer agent for a single CorpusSlice.
    class ChapterIndexerAgent < Agent
      def call(slice)
        slice_obj = CorpusSlice.from_h(slice)
        store     = KnowledgeStore.build(Agentkit.config.rag.store)
        indexer   = Indexer.new(corpus_name: slice_obj.corpus_name, store: store)
        res       = indexer.index_slice(slice_obj)

        Result.ok({
          slice_id:      res[:slice_id],
          chapter_index: res[:chapter_index],
          title:         res[:title],
          vectors:       res[:vectors],
          chunks:        res[:chunks]
        })
      end
    end

    # Chapter analysis agent (extracts references, key concepts).
    class ChapterAnalystAgent < Agent
      def call(indexed_chapter)
        title = indexed_chapter[:title] || indexed_chapter["title"]
        ci    = indexed_chapter[:chapter_index] || indexed_chapter["chapter_index"]

        Result.ok({
          chapter:    title,
          chapter_index: ci,
          references: ["Reference for Chapter #{ci}: #{title}"],
          summary:    "Chapter #{ci} analyzed"
        })
      end
    end

    # Tree reduce agent to aggregate chapter analyses into a final report.
    class BibliographyReportAgent < Agent
      def call(input)
        analyses = Array(input).map { |r| r.is_a?(Agentkit::Result) ? r.value : r }
        merged   = analyses.flat_map { |a| Array(a[:references] || a["references"]) }.uniq

        Result.ok({
          total_references: merged.size,
          by_chapter:       analyses.map { |a| { (a[:chapter] || a["chapter"]) => (a[:references] || a["references"]) } },
          global_index:     merged
        })
      end
    end

    # Orquestación de RAG Distribuida (Parallel Sub-Agent Pattern).
    # Multi-step map/reduce flow for partitioning, parallel indexing, chapter analysis, and report reduction.
    class CoordinatorFlow < Agentkit::Flow
      input :pdf_text, :pdf_path, :corpus_name, :strategy, :max_slice_mb, :max_concurrency

      step :parse, agent: PDFChapterChunkerAgent,
           input: ->(ctx) {
             {
               pdf_text:     ctx.input[:pdf_text],
               pdf_path:     ctx.input[:pdf_path],
               corpus_name:  ctx.input[:corpus_name],
               strategy:     ctx.input[:strategy],
               max_slice_mb: ctx.input[:max_slice_mb]
             }
           }

      map  :index_chapters,
           over:            ->(ctx) { ctx[:parse][:slices] },
           agent:           ChapterIndexerAgent,
           max_concurrency: ->(ctx) { ctx.input[:max_concurrency] || 4 }

      join :index_chapters, on: :all_settled

      map  :analyze_chapters,
           over:            ->(ctx) { ctx[:index_chapters].value },
           agent:           ChapterAnalystAgent,
           max_concurrency: ->(ctx) { ctx.input[:max_concurrency] || 4 }

      join :analyze_chapters, on: :all_settled

      reduce :synthesize,
             target: :analyze_chapters,
             agent:  BibliographyReportAgent,
             chunk:  10
    end
  end
end
