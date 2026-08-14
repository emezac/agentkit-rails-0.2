# frozen_string_literal: true

require_relative "rag/bm25"
require_relative "rag/chunker"
require_relative "rag/corpus_slice"
require_relative "rag/chapter_chunker"
require_relative "rag/corpus"
require_relative "rag/knowledge_store"
require_relative "rag/indexer"
require_relative "rag/retriever"
require_relative "rag/pipeline"
require_relative "rag/coordinator_flow"

module Agentkit
  # Native Retrieval-Augmented Generation (RAG) module for AgentKit.
  module RAG
    class << self
      def index(corpus_name: "default_corpus", source: nil, chunk_documents: true, store: nil)
        indexer = Indexer.new(corpus_name: corpus_name, store: store)
        indexer.index_corpus(source, chunk_documents: chunk_documents)
      end

      def index_slice(slice, store: nil)
        indexer = Indexer.new(store: store)
        indexer.index_slice(slice)
      end

      def retrieve(query, corpus_name: "default_corpus", top_k: nil, filter: {}, store: nil)
        retriever = Retriever.new(store: store)
        retriever.retrieve(query, corpus_name: corpus_name, top_k: top_k, filter: filter)
      end

      def generate(query, corpus_name: "default_corpus", top_k: nil, filter: {}, system_prompt: nil, store: nil, &block)
        retriever = Retriever.new(store: store)
        pipeline  = Pipeline.new(retriever: retriever)
        pipeline.generate(query, corpus_name: corpus_name, top_k: top_k, filter: filter, system_prompt: system_prompt, &block)
      end

      def cleanup_partial_index(corpus_name, store: nil)
        k_store = store || KnowledgeStore.build(Agentkit.config.rag.store)
        k_store.cleanup_partial_index(corpus_name)
      end
      alias drop_corpus cleanup_partial_index
    end
  end
end
