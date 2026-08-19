# frozen_string_literal: true

module Agentkit
  module RAG
    # Hybrid retriever combining dense vector search and BM25 sparse keyword search via RRF.
    class Retriever
      def initialize(store: nil, config: nil, tenant_key: nil, account_id: nil)
        @config = config || Agentkit.config.rag
        @store  = store || KnowledgeStore.build(@config.store)
        @tenant_scope = RAG.resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
      end

      attr_reader :config, :store, :tenant_scope

      def retrieve(query, corpus_name: "default_corpus", top_k: nil, filter: {})
        top_k ||= config.top_k
        fetch_k = filter.any? ? top_k * 3 : top_k * 2

        if config.hybrid_search
          vec_res  = retrieve_vector(corpus_name, query, fetch_k: fetch_k, filter: filter)
          bm25_res = retrieve_bm25(corpus_name, query, fetch_k: fetch_k, filter: filter)
          rrf_combine(vec_res, bm25_res, top_k: top_k, rrf_k: config.rrf_k)
        else
          retrieve_vector(corpus_name, query, fetch_k: top_k, filter: filter)
        end
      end

      private

      def retrieve_vector(corpus_name, query, fetch_k:, filter:)
        q_emb = query_vector(query)
        return retrieve_bm25(corpus_name, query, fetch_k: fetch_k, filter: filter) if q_emb.nil?

        results = store.vector_search(
          corpus_name, q_emb, limit: fetch_k, threshold: 0.8, filter: filter, **tenant_scope
        )
        results.map do |doc, dist|
          doc.merge("score" => 1.0 - dist, "distance" => dist)
        end
      end

      def retrieve_bm25(corpus_name, query, fetch_k:, filter:)
        store.keyword_search(corpus_name, query, limit: fetch_k, filter: filter, **tenant_scope).map do |doc|
          doc.merge("bm25_score" => 1.0)
        end
      end

      def rrf_combine(vec_results, bm25_results, top_k:, rrf_k: 60)
        rrf_scores = Hash.new(0.0)
        doc_map = {}

        vec_results.each_with_index do |doc, rank|
          idx = doc["id"] || doc[:id]
          doc_map[idx] = doc
          rrf_scores[idx] += 1.0 / (rrf_k + rank + 1)
        end

        bm25_results.each_with_index do |doc, rank|
          idx = doc["id"] || doc[:id]
          doc_map[idx] ||= doc
          rrf_scores[idx] += 1.0 / (rrf_k + rank + 1)
        end

        sorted_indices = rrf_scores.sort_by { |_idx, score| -score }.first(top_k)
        sorted_indices.map do |idx, rrf_score|
          doc_map[idx].merge("score" => rrf_score, "rrf_score" => rrf_score)
        end
      end

      def query_vector(query)
        Memory.embedder.query_vector(query, Agentkit.config.memory) || Array.new(config.embedding_dimensions) { rand }
      rescue StandardError
        nil
      end
    end
  end
end
