# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Test agents
# ---------------------------------------------------------------------------
# NOTE: Result.ok MUST receive the hash as a positional arg — keyword args go
# into metadata, not value:
#   Result.ok({key: val})   → value = {key: val}   ✓
#   Result.ok(key: val)     → value = nil           ✗

class TestPDFChapterChunkerAgent < Agentkit::Agent
  def call(input)
    pdf_text    = input[:pdf_text]    || input["pdf_text"]
    corpus_name = input[:corpus_name] || input["corpus_name"]
    docs        = pdf_text.split("\n\n").map { |t| { "text" => t } }
    chunker     = Agentkit::RAG::ChapterChunker.new(strategy: :heading_regex)
    slices      = chunker.split(docs, corpus_name: corpus_name)
    Agentkit::Result.ok({ slices: slices.map(&:to_h), total_chapters: slices.size })
  end
end

class TestChapterIndexerAgent < Agentkit::Agent
  def call(slice)
    slice_obj = Agentkit::RAG::CorpusSlice.from_h(slice)
    store     = Agentkit::RAG::KnowledgeStore.build(:memory)
    indexer   = Agentkit::RAG::Indexer.new(corpus_name: slice_obj.corpus_name, store: store)
    res       = indexer.index_slice(slice_obj)

    Agentkit::Result.ok({
      slice_id:      res[:slice_id],
      chapter_index: res[:chapter_index],
      title:         res[:title],
      vectors:       res[:vectors],
      chunks:        res[:chunks]
    })
  end
end

class TestChapterAnalystAgent < Agentkit::Agent
  # Payload keys may be strings (Coder serialises symbol keys to strings across
  # map branches) — always fall back to the string form.
  def call(indexed_chapter)
    title = indexed_chapter[:title]         || indexed_chapter["title"]
    ci    = indexed_chapter[:chapter_index] || indexed_chapter["chapter_index"]

    Agentkit::Result.ok({
      chapter:    title,
      references: ["Author (2026). Chapter #{ci} – #{title}"],
      summary:    "Chapter #{ci} analyzed"
    })
  end
end

class TestBibliographyReportAgent < Agentkit::Agent
  # Called by the tree-reduce with an Array of leaf hashes (first pass) or
  # intermediate hashes (subsequent passes).  Both forms carry :references.
  def call(input)
    analyses = Array(input).map { |r| r.is_a?(Agentkit::Result) ? r.value : r }
    merged   = analyses.flat_map { |a| Array(a[:references] || a["references"]) }.uniq

    Agentkit::Result.ok({
      total_references: merged.size,
      by_chapter:       analyses.map { |a|
        { (a[:chapter] || a["chapter"]) => (a[:references] || a["references"]) }
      },
      global_index: merged
    })
  end
end

# ---------------------------------------------------------------------------
# Flow definition
# ---------------------------------------------------------------------------

class TestRAGCoordinatorFlow < Agentkit::Flow
  input :pdf_text, :corpus_name

  step :parse, agent: TestPDFChapterChunkerAgent,
       input: ->(ctx) { { pdf_text: ctx.input[:pdf_text], corpus_name: ctx.input[:corpus_name] } }

  # ctx[:parse] is Result.ok({slices: [...], ...}); Result#[] looks up inside value
  map  :index_chapters,
       over:            ->(ctx) { ctx[:parse][:slices] },
       agent:           TestChapterIndexerAgent,
       max_concurrency: 4

  join :index_chapters, on: :all_settled

  # ctx[:index_chapters] is the StepResults from the map (join stores to
  # :index_chapters_join, NOT :index_chapters).  StepResults#value returns an
  # Array of the unwrapped ok values.
  map  :analyze_chapters,
       over:  ->(ctx) { ctx[:index_chapters].value },
       agent: TestChapterAnalystAgent

  join :analyze_chapters, on: :all_settled

  # Reduce all chapter analyses into a single bibliography report.
  # chunk: 10 ensures a single pass for ≤10 chapters (avoids tree-reduce
  # format mismatch in unit tests).
  reduce :synthesize,
         target: :analyze_chapters,
         agent:  TestBibliographyReportAgent,
         chunk:  10
end

# ---------------------------------------------------------------------------
# Spec
# ---------------------------------------------------------------------------

RSpec.describe "RAG Parallel Coordinator Flow" do
  before do
    Agentkit::Flow.test_mode!
    Agentkit::RAG::KnowledgeStore.build(:memory).delete_all
  end

  it "orchestrates PDF chapter chunking, parallel indexing, analysis and tree reduction" do
    sample_pdf_text = <<~PDF
      Chapter 1: Security Safeguards
      Administrative safeguards mandate security management processes.

      Chapter 2: Privacy Rules
      Patient consent is required for non-routine disclosure.

      Chapter 3: Technical Controls
      Audit controls and access logging must be enabled.
    PDF

    res = TestRAGCoordinatorFlow.call(
      pdf_text: sample_pdf_text,
      corpus_name: "test_oxford_handbook"
    )

    expect(res).to be_ok
    data = res.value
    expect(data[:total_references]).to eq(3)
    expect(data[:global_index].size).to eq(3)
  end
end
