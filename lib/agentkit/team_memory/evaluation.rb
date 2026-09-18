# frozen_string_literal: true

require "json"

module Agentkit
  module TeamMemory
    # Reproducible labeled retrieval evaluation. It reports measured values
    # only; callers supply a dataset or a retrieval block.
    module Evaluation
      class << self
        def sample_dataset_path
          File.expand_path("../../../config/graph_retrieval_eval.json", __dir__)
        end

        def run(dataset, strategies: %i[keyword hybrid_graph], &retriever)
          data = dataset.is_a?(String) ? JSON.parse(File.read(dataset)) : dataset.to_h
          cases = Array(data["cases"] || data[:cases])
          hidden = Array(data["hidden_ids"] || data[:hidden_ids]).map(&:to_s)
          indexing_started = monotonic
          runner = retriever || dataset_runner(data)
          indexing_ms = retriever ? nil : ((monotonic - indexing_started) * 1_000.0).round(3)
          started = monotonic
          results = Array(strategies).to_h do |strategy|
            measurements = cases.map do |test_case|
              before = monotonic
              rows = Array(runner.call(strategy.to_sym, test_case))
              latency = (monotonic - before) * 1_000.0
              ids = rows.map { |row| field(row, :id) || field(row, :external_ref) }.compact.map(&:to_s)
              relevant = Array(field(test_case, :relevant_ids)).map(&:to_s)
              k = (field(test_case, :k) || 10).to_i
              { ids: ids.first(k), relevant: relevant, latency_ms: latency,
                convergence_observed: rows.any? { |row| has_field?(row, :converged) },
                converged: rows.any? && rows.all? { |row| field(row, :converged) == true },
                fallback: rows.any? { |row| !field(row, :graph_degraded_reason).nil? },
                no_path: rows.count { |row| field(row, :supporting_paths).nil? || Array(field(row, :supporting_paths)).empty? },
                visited_nodes: rows.map { |row| field(row, :visited_nodes).to_i }.max.to_i,
                visited_edges: rows.map { |row| field(row, :visited_edges).to_i }.max.to_i,
                hidden: ids & hidden }
            end
            [strategy.to_s, summarize(measurements)]
          end
          { dataset_digest: Graph.digest_for(data), query_count: cases.size,
            indexing_ms: indexing_ms, strategies: results,
            duration_ms: ((monotonic - started) * 1_000.0).round(3) }
        end

        def summarize(measurements)
          count = measurements.size
          latencies = measurements.map { |row| row[:latency_ms] }.sort
          {
            recall_at_k: average(measurements) { |row| recall(row[:ids], row[:relevant]) },
            ndcg_at_k: average(measurements) { |row| ndcg(row[:ids], row[:relevant]) },
            mrr: average(measurements) { |row| reciprocal_rank(row[:ids], row[:relevant]) },
            latency_p50_ms: percentile(latencies, 0.50), latency_p95_ms: percentile(latencies, 0.95),
            convergence_rate: convergence_rate(measurements),
            fallback_rate: count.zero? ? 0.0 : measurements.count { |row| row[:fallback] }.to_f / count,
            no_path_rate: count.zero? ? 0.0 : measurements.sum { |row| row[:no_path] }.to_f / [measurements.sum { |row| row[:ids].size }, 1].max,
            hidden_inferences: measurements.sum { |row| row[:hidden].size },
            visited_nodes_mean: average(measurements) { |row| row[:visited_nodes] },
            visited_edges_mean: average(measurements) { |row| row[:visited_edges] }
          }.transform_values { |value| value.is_a?(Float) ? value.round(6) : value }
        end

        private

        def dataset_runner(data)
          documents = Array(data["documents"])
          tenant = data["tenant_key"] || "agentkit-graph-eval"
          corpus = data["corpus_name"] || "graph-eval"
          name = "#{data['graph_name'] || 'GraphEval'}-#{Graph.digest_for(data)[7, 12]}"
          owner = "agentkit-graph-eval"
          store = RAG::KnowledgeStore.build(:memory)
          context = Context.new(user: owner, tenant_key: tenant)
          previous_level = Agentkit.config.memory.level
          Agentkit.config.team_memory.store = :memory
          TeamMemory.reset!
          Agentkit.config.memory.level = :keyword
          Agentkit.with_context(context) do
            store.cleanup_partial_index(corpus, tenant_key: tenant)
            RAG.index(corpus_name: corpus, source: documents, store: store)
            RAG.build_graph(name: name, chunks: documents, visibility: "private", owner_id: owner)
          end
          Agentkit.config.memory.level = previous_level
          lambda do |strategy, test_case|
            Agentkit.with_context(context) do
              RAG.retrieve(field(test_case, :query), corpus_name: corpus,
                           top_k: field(test_case, :k) || 10, store: store,
                           strategy: strategy == :hybrid_graph ? :hybrid_graph : nil,
                           graph: strategy == :hybrid_graph ? name : nil, explain: true)
            end
          end
        rescue StandardError
          Agentkit.config.memory.level = previous_level if defined?(previous_level)
          raise
        end

        def recall(ids, relevant)
          return 0.0 if relevant.empty?

          (ids & relevant).size.to_f / relevant.size
        end

        def ndcg(ids, relevant)
          return 0.0 if relevant.empty?

          dcg = ids.each_with_index.sum { |id, index| relevant.include?(id) ? 1.0 / Math.log2(index + 2) : 0.0 }
          ideal = [ids.size, relevant.size].min.times.sum { |index| 1.0 / Math.log2(index + 2) }
          ideal.zero? ? 0.0 : dcg / ideal
        end

        def reciprocal_rank(ids, relevant)
          index = ids.index { |id| relevant.include?(id) }
          index ? 1.0 / (index + 1) : 0.0
        end

        def average(rows)
          return 0.0 if rows.empty?

          rows.sum { |row| yield(row) } / rows.size
        end

        def percentile(values, fraction)
          return 0.0 if values.empty?

          values[[(values.size * fraction).ceil - 1, 0].max].round(3)
        end

        def convergence_rate(measurements)
          observed = measurements.select { |row| row[:convergence_observed] }
          return nil if observed.empty?

          observed.count { |row| row[:converged] }.to_f / observed.size
        end

        def field(value, key)
          value.is_a?(Hash) ? (value[key] || value[key.to_s]) : value.public_send(key)
        end

        def has_field?(value, key)
          value.is_a?(Hash) ? (value.key?(key) || value.key?(key.to_s)) : value.respond_to?(key)
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
