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

      def retrieve(query, corpus_name: "default_corpus", top_k: nil, filter: {}, strategy: nil,
                   graph: nil, explain: false, graph_required: false)
        top_k ||= config.top_k
        fetch_k = filter.any? ? top_k * 3 : top_k * 2

        q_emb = query_vector(query)
        if q_emb.nil?
          emit_degraded(corpus_name)
          bm25 = retrieve_bm25(corpus_name, query, fetch_k: graph_strategy?(strategy) ? fetch_k : top_k, filter: filter)
          base = mark_strategy(bm25.first(top_k), "keyword_only")
          return graph_retrieve(query, corpus_name, graph, [bm25], base, top_k, explain, graph_required) if graph_strategy?(strategy)

          return base
        end

        if config.hybrid_search
          vec_res  = retrieve_vector(corpus_name, q_emb, fetch_k: fetch_k, filter: filter)
          bm25_res = retrieve_bm25(corpus_name, query, fetch_k: fetch_k, filter: filter)
          base = mark_strategy(rrf_combine(vec_res, bm25_res, top_k: top_k, rrf_k: config.rrf_k), "hybrid")
          return graph_retrieve(query, corpus_name, graph, [vec_res, bm25_res], base, top_k, explain, graph_required) if graph_strategy?(strategy)

          base
        else
          vector = retrieve_vector(corpus_name, q_emb, fetch_k: graph_strategy?(strategy) ? fetch_k : top_k, filter: filter)
          base = mark_strategy(vector.first(top_k), "vector")
          return graph_retrieve(query, corpus_name, graph, [vector], base, top_k, explain, graph_required) if graph_strategy?(strategy)

          base
        end
      end

      private

      def retrieve_vector(corpus_name, q_emb, fetch_k:, filter:)
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
        rrf_rankings([vec_results, bm25_results], top_k: top_k, rrf_k: rrf_k)
      end

      def rrf_rankings(rankings, top_k:, rrf_k: 60)
        rrf_scores = Hash.new(0.0)
        doc_map = {}

        rankings.each do |ranking|
          ranking.each_with_index do |doc, rank|
            idx = document_key(doc)

            doc_map[idx.to_s] ||= doc
            rrf_scores[idx.to_s] += 1.0 / (rrf_k + rank + 1)
          end
        end

        sorted_indices = rrf_scores.sort_by { |_idx, score| -score }.first(top_k)
        sorted_indices.map do |idx, rrf_score|
          doc_map[idx].merge("score" => rrf_score, "rrf_score" => rrf_score)
        end
      end

      def graph_retrieve(query, corpus_name, graph, base_rankings, fallback, top_k, explain, required)
        current = Context.resolve
        graph_context = Context.new(user: current.user, account: tenant_scope[:account_id],
                                    tenant_key: tenant_scope[:tenant_key], principal: current.principal,
                                    metadata: current.metadata)
        activation = TeamMemory::SpreadingActivation.retrieve(
          query, graph: graph, seeds: base_rankings.flatten, top_k: [top_k * 2, 1].max,
          context: graph_context, required: required
        )
        if activation.degraded?
          safe_fallback = if activation.visibility_applied?
                            fallback.select do |doc|
                              activation.visible_external_ref?(doc["id"] || doc[:id] || doc["chunk_id"] || doc[:chunk_id])
                            end
                          else
                            fallback
                          end
          return safe_fallback.map { |doc| doc.merge("graph_degraded_reason" => activation.degraded_reason) }
        end

        visible_rankings = base_rankings.map do |ranking|
          ranking.select do |doc|
            activation.visible_external_ref?(doc["id"] || doc[:id] || doc["chunk_id"] || doc[:chunk_id])
          end
        end
        docs = visible_rankings.flatten.each_with_object({}) do |doc, memo|
          id = doc["id"] || doc[:id]
          memo[id.to_s] ||= doc if id
        end
        missing_refs = activation.ranked.map { |item| item["external_ref"].to_s }.reject { |id| docs.key?(id) }
        store.find_by_ids(corpus_name, missing_refs, **tenant_scope).each do |doc|
          id = doc["id"] || doc[:id] || doc["chunk_id"] || doc[:chunk_id]
          docs[id.to_s] = doc if id
        end
        graph_docs = activation.ranked.filter_map do |item|
          doc = docs[item["external_ref"].to_s]
          doc&.merge("graph_score" => item["graph_score"],
                     "supporting_paths" => item["supporting_paths"])
        end
        graph_by_ref = activation.ranked.to_h { |item| [item["external_ref"].to_s, item] }
        combined = rrf_rankings([*visible_rankings, graph_docs], top_k: top_k, rrf_k: config.rrf_k)
        combined.map do |doc|
          id = (doc["id"] || doc[:id]).to_s
          graph_item = graph_by_ref[id]
          enriched = doc.merge("retrieval_strategy" => "hybrid_graph")
          if graph_item
            enriched = enriched.merge("graph_score" => graph_item["graph_score"],
                                      "supporting_paths" => graph_item["supporting_paths"])
          end
          explain ? enriched.merge(activation.explanation.reject { |key, _| key == "supporting_paths" }) : enriched
        end
      end

      def graph_strategy?(strategy) = strategy&.to_sym == :hybrid_graph

      def document_key(doc)
        explicit = doc["id"] || doc[:id] || doc["chunk_id"] || doc[:chunk_id] ||
                   doc["external_ref"] || doc[:external_ref]
        return explicit.to_s if explicit

        text = doc["text"] || doc[:text] || doc["content"] || doc[:content]
        source = doc["source"] || doc[:source]
        "content:#{Digest::SHA256.hexdigest([source, text].join("\0"))}"
      end

      def query_vector(query)
        Memory.embedder.query_vector(query, Agentkit.config.memory)
      rescue StandardError
        nil
      end

      def mark_strategy(results, strategy)
        results.map { |doc| doc.merge("retrieval_strategy" => strategy) }
      end

      def emit_degraded(corpus_name)
        Telemetry.emit(
          "rag.retrieval.degraded",
          dims: { cause: "query_embedding_unavailable", strategy: "keyword_only",
                  corpus: corpus_name.to_s, tenant: tenant_scope[:tenant_key] },
          measures: { count: 1 }
        )
      end
    end
  end
end
