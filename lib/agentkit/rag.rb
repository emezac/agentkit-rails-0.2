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
    GLOBAL_TENANT_KEY = "__global__"

    class << self
      def index(corpus_name: "default_corpus", source: nil, chunk_documents: true, store: nil,
                tenant_key: nil, account_id: nil)
        indexer = Indexer.new(
          corpus_name: corpus_name, store: store, tenant_key: tenant_key, account_id: account_id
        )
        indexer.index_corpus(source, chunk_documents: chunk_documents)
      end

      def index_slice(slice, store: nil, tenant_key: nil, account_id: nil)
        indexer = Indexer.new(store: store, tenant_key: tenant_key, account_id: account_id)
        indexer.index_slice(slice)
      end

      def retrieve(query, corpus_name: "default_corpus", top_k: nil, filter: {}, store: nil,
                   tenant_key: nil, account_id: nil, strategy: nil, graph: nil, explain: false,
                   graph_required: false)
        retriever = Retriever.new(store: store, tenant_key: tenant_key, account_id: account_id)
        retriever.retrieve(query, corpus_name: corpus_name, top_k: top_k, filter: filter,
                           strategy: strategy, graph: graph, explain: explain,
                           graph_required: graph_required)
      end

      def build_graph(name:, chunks:, team_id: nil, visibility: "team", owner_id: nil,
                      bindings: [], tenant_key: nil, account_id: nil)
        asset = TeamMemory.create_asset(asset_type: "rag", name: name, team_id: team_id,
                                        visibility: visibility, owner_id: owner_id, bindings: bindings,
                                        tenant_key: tenant_key,
                                        account_id: account_id)
        TeamMemory::Graph.build_rag(asset: asset, chunks: chunks)
      end

      def generate(query, corpus_name: "default_corpus", top_k: nil, filter: {}, system_prompt: nil,
                   store: nil, tenant_key: nil, account_id: nil, &block)
        retriever = Retriever.new(store: store, tenant_key: tenant_key, account_id: account_id)
        pipeline  = Pipeline.new(retriever: retriever)
        pipeline.generate(query, corpus_name: corpus_name, top_k: top_k, filter: filter, system_prompt: system_prompt, &block)
      end

      def cleanup_partial_index(corpus_name, store: nil, tenant_key: nil, account_id: nil)
        scope = resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
        k_store = store || KnowledgeStore.build(Agentkit.config.rag.store)
        k_store.cleanup_partial_index(corpus_name, **scope)
      end
      alias drop_corpus cleanup_partial_index

      def resolve_tenant_scope(tenant_key: nil, account_id: nil)
        context = Context.resolve
        resolved_key = tenant_key || context.tenant_key
        if Agentkit.config.multi_tenant && resolved_key.nil?
          raise ConfigurationError, "RAG requires a tenant_key when multi_tenant is enabled"
        end

        resolved_account_id = account_id || id_of(context.account)
        { tenant_key: resolved_key || GLOBAL_TENANT_KEY, account_id: resolved_account_id }
      end

      private

      def id_of(value)
        value.respond_to?(:id) ? value.id : value
      end
    end
  end
end
