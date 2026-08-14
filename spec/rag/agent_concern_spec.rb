# frozen_string_literal: true

require "spec_helper"

class TestKnowledgeAgent < Agentkit::Agent
  use_knowledge :test_corpus, filter: { department: "engineering" }

  def call(input)
    query = input[:query]
    chunks = rag_retrieve(query)
    Agentkit::Result.ok({ chunks: chunks })
  end
end

class ExplicitKnowledgeAgent < Agentkit::Agent
  def call(input)
    chunks = rag_retrieve(input[:query], corpus: input[:corpus])
    Agentkit::Result.ok({ chunks: chunks })
  end
end

RSpec.describe Agentkit::RAG::AgentConcern do
  let(:mem_store) { Agentkit::RAG::KnowledgeStore.build(:memory) }

  before do
    Agentkit::Flow.test_mode!
    Agentkit.config.rag.store = :memory
    mem_store.delete_all

    Agentkit::RAG.index(
      corpus_name: "test_corpus",
      source: [
        { "text" => "Engineering security standards: use OAuth2.", "department" => "engineering" },
        { "text" => "HR guidelines: 20 days PTO.", "department" => "hr" }
      ],
      chunk_documents: false,
      store: mem_store
    )

    Agentkit::RAG.index(
      corpus_name: "custom_corpus",
      source: [
        { "text" => "Custom corpus info." }
      ],
      chunk_documents: false,
      store: mem_store
    )
  end

  it "retrieves knowledge using class-declared default corpus and filter" do
    agent = TestKnowledgeAgent.new
    res = agent.call(query: "security")

    expect(res).to be_ok
    expect(res.value[:chunks]).not_to be_empty
    expect(res.value[:chunks].first["text"]).to include("Engineering security")
  end

  it "allows explicit corpus override at invocation time" do
    agent = ExplicitKnowledgeAgent.new
    res = agent.call(query: "Custom", corpus: "custom_corpus")

    expect(res).to be_ok
    expect(res.value[:chunks]).not_to be_empty
    expect(res.value[:chunks].first["text"]).to include("Custom corpus info")
  end

  it "raises ConfigurationError when retrieving without a configured corpus" do
    agent = ExplicitKnowledgeAgent.new
    expect {
      agent.call(query: "test")
    }.to raise_error(Agentkit::ConfigurationError, /has no knowledge corpus configured/)
  end

  it "builds formatted rag_context string" do
    agent = TestKnowledgeAgent.new
    ctx_text = agent.rag_context("security")
    expect(ctx_text).to include("[1] Engineering security standards")
  end
end
