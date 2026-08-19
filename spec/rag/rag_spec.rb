# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::RAG do
  before do
    Agentkit::RAG::KnowledgeStore.build(:memory).delete_all
  end

  describe Agentkit::RAG::BM25Index do
    it "indexes and retrieves documents using Okapi BM25" do
      docs = [
        { "id" => "doc1", "text" => "HIPAA security rule requires administrative safeguards" },
        { "id" => "doc2", "text" => "Patient health information privacy violations and penalties" },
        { "id" => "doc3", "text" => "Unsecured transfer of PDA data to external database" }
      ]

      index = described_class.new
      index.build(docs)

      results = index.search("privacy violations", 2)
      expect(results.first.first).to eq(1) # doc2 index
    end
  end

  describe Agentkit::RAG::ChapterChunker do
    it "splits text documents by heading regex into CorpusSlices" do
      docs = [
        { "text" => "Chapter 1: Overview\nThis is the introduction to compliance." },
        { "text" => "Chapter 2: Security Rules\nSecurity rules mandate password locking." }
      ]

      chunker = described_class.new(strategy: :heading_regex)
      slices = chunker.split(docs, corpus_name: "test_book")

      expect(slices.size).to eq(2)
      expect(slices.first.title).to eq("Chapter 1: Overview")
      expect(slices.last.title).to eq("Chapter 2: Security Rules")
      expect(slices.first.corpus_name).to eq("test_book")
    end

    it "splits documents by size budget" do
      docs = [
        { "text" => "A" * 100 },
        { "text" => "B" * 100 },
        { "text" => "C" * 100 }
      ]

      chunker = described_class.new(strategy: :size_budget)
      slices = chunker.send(:split_by_size_budget, docs, "budget_corpus", max_bytes: 250)

      expect(slices.size).to eq(2)
    end
  end

  describe Agentkit::RAG::CorpusSlice do
    it "serializes and deserializes cleanly" do
      slice = described_class.new(
        corpus_name: "test",
        chapter_index: 1,
        title: "Ch 1",
        chunks: [{ "text" => "hello" }]
      )

      hash = slice.to_h
      restored = described_class.from_h(hash)

      expect(restored.chapter_index).to eq(1)
      expect(restored.title).to eq("Ch 1")
      expect(restored.chunks).to eq([{ "text" => "hello" }])
    end
  end

  describe "End-to-End RAG workflow (InMemory)" do
    let(:store) { Agentkit::RAG::KnowledgeStore.build(:memory) }

    it "indexes, retrieves, and generates answers" do
      corpus_docs = [
        { "id" => "c1", "text" => "Violations include sign-in sheets exposing prescriptions.", "chapter_index" => 1 },
        { "id" => "c2", "text" => "Computer monitors visible to unauthorized personnel is a violation.", "chapter_index" => 2 }
      ]

      res = Agentkit::RAG.index(corpus_name: "hipaa", source: corpus_docs, store: store)
      expect(res[:chunks]).to eq(2)

      retrieved = Agentkit::RAG.retrieve("monitors visible", corpus_name: "hipaa", top_k: 1, store: store)
      expect(retrieved.first["text"]).to include("monitors visible")

      fake_llm.respond_with("Computer monitors visible to unauthorized personnel is a HIPAA violation.")
      result = Agentkit::RAG.generate("What is a violation?", corpus_name: "hipaa", store: store)

      expect(result["answer"]).to include("HIPAA violation")
      expect(result["retrieved"]).not_to be_empty
    end

    it "filters retrieval by chapter_index" do
      corpus_docs = [
        { "id" => "c1", "text" => "Audit trails are mandatory.", "chapter_index" => 1 },
        { "id" => "c2", "text" => "Printed materials must be shredded.", "chapter_index" => 2 }
      ]

      Agentkit::RAG.index(corpus_name: "hipaa", source: corpus_docs, store: store)

      retrieved = Agentkit::RAG.retrieve("shredded", corpus_name: "hipaa", filter: { chapter_index: 2 }, store: store)
      expect(retrieved.first["chapter_index"]).to eq(2)
    end

    it "isolates identical corpus names between tenants" do
      tenant_a = Agentkit::Context.new(tenant_key: "tenant:a")
      tenant_b = Agentkit::Context.new(tenant_key: "tenant:b")

      Agentkit.with_context(tenant_a) do
        Agentkit::RAG.index(corpus_name: "handbook", source: "alpha-only policy", store: store)
      end
      Agentkit.with_context(tenant_b) do
        Agentkit::RAG.index(corpus_name: "handbook", source: "beta-only policy", store: store)
      end

      results_a = Agentkit.with_context(tenant_a) do
        Agentkit::RAG.retrieve("policy", corpus_name: "handbook", store: store)
      end
      results_b = Agentkit.with_context(tenant_b) do
        Agentkit::RAG.retrieve("policy", corpus_name: "handbook", store: store)
      end

      expect(results_a.map { |row| row["text"] }).to contain_exactly(include("alpha-only"))
      expect(results_b.map { |row| row["text"] }).to contain_exactly(include("beta-only"))
    end

    it "requires an explicit context when multi-tenancy is enabled" do
      Agentkit.config.multi_tenant = true

      expect do
        Agentkit::RAG.index(corpus_name: "handbook", source: "unscoped", store: store)
      end.to raise_error(Agentkit::ConfigurationError, /requires a tenant_key/)
    ensure
      Agentkit.config.multi_tenant = false
    end
  end
end
