# frozen_string_literal: true

require "set"
require "timeout"

module Agentkit
  module TeamMemory
    # Bounded Personalized PageRank over an already-authorized graph snapshot.
    module SpreadingActivation
      DIRECTIONS = %i[outbound inbound both].freeze
      STRATEGIES = %i[personalized_pagerank].freeze

      class ActivationTrace
        attr_reader :snapshot_digest, :query_digest, :visible_node_aliases, :edges,
                    :frames, :algorithm, :parameters, :generated_at

        def initialize(snapshot_digest:, query_digest:, visible_node_aliases:, edges:, frames:,
                       algorithm:, parameters:, generated_at: Time.now.utc)
          @snapshot_digest = snapshot_digest
          @query_digest = query_digest
          @visible_node_aliases = visible_node_aliases.freeze
          @edges = edges.freeze
          @frames = frames.freeze
          @algorithm = algorithm.to_s
          @parameters = parameters.freeze
          @generated_at = generated_at
          freeze
        end

        def to_h
          { snapshot_digest: snapshot_digest, query_digest: query_digest,
            visible_node_aliases: visible_node_aliases, edges: edges, frames: frames,
            algorithm: algorithm, parameters: parameters, generated_at: generated_at }
        end
      end

      class Result
        include Enumerable
        attr_reader :ranked, :snapshot_digest, :seed_ids, :supporting_paths,
                    :iterations, :converged, :trace, :degraded_reason, :visited_nodes, :visited_edges

        def initialize(ranked:, snapshot_digest: nil, seed_ids: [], supporting_paths: {},
                       iterations: 0, converged: false, trace: nil, degraded_reason: nil,
                       visited_nodes: 0, visited_edges: 0, visible_external_refs: [], visibility_applied: false)
          @ranked = ranked.freeze
          @snapshot_digest = snapshot_digest
          @seed_ids = seed_ids.freeze
          @supporting_paths = supporting_paths.freeze
          @iterations = iterations
          @converged = converged
          @trace = trace
          @degraded_reason = degraded_reason
          @visited_nodes = visited_nodes
          @visited_edges = visited_edges
          @visible_external_refs = Set.new(visible_external_refs.map(&:to_s)).freeze
          @visibility_applied = visibility_applied
          freeze
        end

        def each(&block) = ranked.each(&block)
        def degraded? = !degraded_reason.nil?
        def converged? = converged
        def visible_external_ref?(value) = @visible_external_refs.include?(value.to_s)
        def visibility_applied? = @visibility_applied

        def explanation
          { "retrieval_strategy" => degraded? ? "hybrid" : "hybrid_graph",
            "graph_snapshot" => snapshot_digest, "seed_ids" => seed_ids,
            "supporting_paths" => supporting_paths, "iterations" => iterations,
            "converged" => converged, "visited_nodes" => visited_nodes,
            "visited_edges" => visited_edges, "degraded_reason" => degraded_reason }.compact
        end
      end

      class << self
        def retrieve(query, graph:, seeds:, strategy: :personalized_pagerank, direction: :both,
                     top_k: 10, context: Context.resolve, required: false)
          validate_options!(strategy, direction)
          started = monotonic
          visible = resolve_visible(graph, context)
          return degraded(:graph_missing, required) unless visible
          return degraded(:graph_stale, required, visible) if stale?(visible.snapshot)

          limits = effective_limits
          if visible.node_count > limits[:nodes] || visible.edge_count > limits[:edges]
            return degraded(:graph_too_large, required, visible)
          end

          seed_scores = resolve_seeds(seeds, visible)
          return degraded(:seeds_not_in_visible_graph, required, visible) if seed_scores.empty?

          bounded_nodes, bounded_edges, parents = bounded_subgraph(visible, seed_scores.keys, direction, limits)
          scores, frames, iterations, converged = personalized_pagerank(
            bounded_nodes, bounded_edges, seed_scores, direction, limits, started
          )
          return degraded(:solver_exhausted, required, visible) unless converged
          aliases = bounded_nodes.to_h { |node| [node.node_id, Graph.alias_for(visible, node.node_id)] }
          ranked_nodes = scores.sort_by { |id, score| [-score, id] }.first([top_k.to_i, limits[:nodes]].min)
          paths = ranked_nodes.to_h do |node_id, _score|
            [aliases.fetch(node_id), visible_path(node_id, parents, aliases)]
          end
          ranked = ranked_nodes.map.with_index do |(node_id, score), index|
            node = bounded_nodes.find { |candidate| candidate.node_id == node_id }
            { "node_id" => aliases.fetch(node_id), "external_ref" => node.external_ref,
              "node_type" => node.node_type, "label" => node.label,
              "graph_score" => score, "graph_rank" => index + 1,
              "supporting_paths" => paths[aliases.fetch(node_id)] }
          end
          trace = build_trace(query, visible, bounded_nodes, bounded_edges, aliases, frames,
                              strategy, direction, limits)
          seed_aliases = seed_scores.keys.map { |id| aliases[id] }.compact
          result = Result.new(ranked: ranked, snapshot_digest: visible.digest,
                              seed_ids: seed_aliases, supporting_paths: paths,
                              iterations: iterations, converged: converged, trace: trace,
                              visited_nodes: bounded_nodes.size, visited_edges: bounded_edges.size,
                              visible_external_refs: visible.nodes.map(&:external_ref), visibility_applied: true)
          Telemetry.emit("graph.activation",
                         dims: { algorithm: strategy.to_s, direction: direction.to_s,
                                 converged: converged, tenant: Graph.opaque(visible.tenant_key) },
                         measures: { nodes: bounded_nodes.size, edges: bounded_edges.size,
                                     iterations: iterations, duration_ms: elapsed_ms(started) })
          result
        rescue ConfigurationError
          raise
        rescue StandardError => error
          degraded(:solver_failed, required, nil, error)
        end

        private

        def validate_options!(strategy, direction)
          raise ConfigurationError, "unknown graph strategy #{strategy.inspect}" unless STRATEGIES.include?(strategy.to_sym)
          raise ConfigurationError, "unknown graph direction #{direction.inspect}" unless DIRECTIONS.include?(direction.to_sym)
        end

        def resolve_visible(graph, context)
          return graph if graph.is_a?(Graph::VisibleSnapshot)
          snapshot = if graph.is_a?(Graph::Snapshot)
                       graph
                     else
                       Graph.latest(graph, tenant_key: context.tenant_key)
                     end
          snapshot && Graph.visible(snapshot, context: context)
        end

        def effective_limits
          config = Agentkit.config.team_memory
          { nodes: [config.graph_max_nodes.to_i, 1].max,
            edges: [config.graph_max_edges.to_i, 1].max,
            hops: [[config.graph_max_hops.to_i, 1].max, 8].min,
            iterations: [[config.graph_max_iterations.to_i, 1].max, 200].min,
            wall_ms: [[config.graph_wall_time_ms.to_i, 1].max, 5_000].min,
            damping: [[config.graph_damping.to_f, 0.5].max, 0.95].min,
            tolerance: [[config.graph_tolerance.to_f, 1.0e-12].max, 1.0e-3].min }
        end

        def stale?(snapshot)
          expires_at = snapshot.metadata[:expires_at] || snapshot.metadata["expires_at"]
          expires_at && Time.parse(expires_at.to_s) <= Time.now
        rescue ArgumentError
          true
        end

        def resolve_seeds(seeds, visible)
          by_id = visible.nodes.to_h { |node| [node.node_id, node] }
          by_ref = visible.nodes.to_h { |node| [node.external_ref.to_s, node] }
          raw = Array(seeds)
          weighted = {}
          raw.each_with_index do |seed, index|
            id = field(seed, :node_id) || field(seed, :external_ref) || field(seed, :id) || seed.to_s
            node = by_id[id.to_s] || by_ref[id.to_s]
            next unless node

            score = field(seed, :score) || field(seed, :rrf_score) || field(seed, :bm25_score)
            score = 1.0 / (index + 1) unless score.to_f.positive?
            weighted[node.node_id] = [weighted[node.node_id].to_f, score.to_f].max
          end
          total = weighted.values.sum
          return {} unless total.positive?

          weighted.transform_values { |score| score / total }
        end

        def bounded_subgraph(visible, seed_ids, direction, limits)
          candidates = adjacency_edges(visible.edges, direction)
          visited = Set.new(seed_ids)
          frontier = seed_ids.dup
          parents = {}
          selected_edges = []
          limits[:hops].times do
            next_frontier = []
            frontier.each do |id|
              candidates[id].each do |edge, target|
                break if selected_edges.size >= limits[:edges]
                selected_edges << edge unless selected_edges.include?(edge)
                next if visited.include?(target) || visited.size >= limits[:nodes]

                visited << target
                parents[target] ||= id
                next_frontier << target
              end
            end
            frontier = next_frontier
            break if frontier.empty? || visited.size >= limits[:nodes] || selected_edges.size >= limits[:edges]
          end
          nodes = visible.nodes.select { |node| visited.include?(node.node_id) }
          ids = nodes.to_h { |node| [node.node_id, true] }
          edges = selected_edges.select { |edge| ids[edge.from_node_id] && ids[edge.to_node_id] }
          [nodes, edges, parents]
        end

        def personalized_pagerank(nodes, edges, seeds, direction, limits, started)
          ids = nodes.map(&:node_id)
          adjacency = transition_adjacency(edges, direction)
          scores = ids.to_h { |id| [id, seeds[id].to_f] }
          frames = [scores.dup]
          converged = false
          iterations = 0
          limits[:iterations].times do |index|
            raise Timeout::Error, "graph activation wall-time exceeded" if elapsed_ms(started) >= limits[:wall_ms]

            next_scores = ids.to_h { |id| [id, (1.0 - limits[:damping]) * seeds[id].to_f] }
            ids.each do |id|
              links = adjacency[id]
              if links.empty?
                next_scores[id] += limits[:damping] * scores[id]
                next
              end
              total = links.sum { |_target, weight| weight }
              if total <= 0
                next_scores[id] += limits[:damping] * scores[id]
              else
                links.each { |target, weight| next_scores[target] += limits[:damping] * scores[id] * weight / total }
              end
            end
            delta = ids.sum { |id| (next_scores[id] - scores[id]).abs }
            scores = next_scores
            frames << scores.dup
            iterations = index + 1
            if delta <= limits[:tolerance]
              converged = true
              break
            end
          end
          [scores, frames, iterations, converged]
        end

        def adjacency_edges(edges, direction)
          map = Hash.new { |hash, key| hash[key] = [] }
          edges.each do |edge|
            map[edge.from_node_id] << [edge, edge.to_node_id] if %i[outbound both].include?(direction.to_sym)
            map[edge.to_node_id] << [edge, edge.from_node_id] if %i[inbound both].include?(direction.to_sym)
          end
          map
        end

        def transition_adjacency(edges, direction)
          multipliers = Agentkit.config.team_memory.graph_edge_multipliers.to_h.transform_keys(&:to_s)
          map = Hash.new { |hash, key| hash[key] = [] }
          edges.each do |edge|
            weight = edge.weight * edge.confidence * multipliers.fetch(edge.edge_type, 1.0).to_f
            next unless weight.finite? && weight.positive?

            map[edge.from_node_id] << [edge.to_node_id, weight] if %i[outbound both].include?(direction.to_sym)
            map[edge.to_node_id] << [edge.from_node_id, weight] if %i[inbound both].include?(direction.to_sym)
          end
          map
        end

        def visible_path(node_id, parents, aliases)
          path = [node_id]
          path.unshift(parents[path.first]) while parents[path.first]
          path.filter_map { |id| aliases[id] }
        end

        def build_trace(query, visible, nodes, edges, aliases, frames, strategy, direction, limits)
          config = Agentkit.config.team_memory
          trace_nodes = nodes.first(config.graph_trace_max_nodes.to_i)
          allowed = trace_nodes.to_h { |node| [node.node_id, true] }
          trace_edges = edges.select { |edge| allowed[edge.from_node_id] && allowed[edge.to_node_id] }
                             .first(config.graph_trace_max_edges.to_i)
          ActivationTrace.new(
            snapshot_digest: visible.digest, query_digest: Graph.digest_for(query.to_s),
            visible_node_aliases: trace_nodes.to_h { |node| [aliases[node.node_id], node.label] },
            edges: trace_edges.map { |edge| [aliases[edge.from_node_id], aliases[edge.to_node_id], edge.edge_type] },
            frames: frames.map do |frame|
              frame.filter_map { |id, score| [aliases[id], score] if allowed[id] }.to_h
            end,
            algorithm: strategy,
            parameters: { direction: direction, damping: limits[:damping],
                          max_hops: limits[:hops], max_iterations: limits[:iterations] }
          )
        end

        def degraded(reason, required, visible = nil, error = nil)
          raise ConfigurationError, "graph retrieval required but unavailable: #{reason}" if required

          Telemetry.emit("graph.activation.degraded",
                         dims: { cause: reason.to_s, error_class: error&.class&.name },
                         measures: { count: 1 })
          Result.new(ranked: [], snapshot_digest: visible&.digest, degraded_reason: reason.to_s,
                     visited_nodes: visible&.node_count.to_i, visited_edges: visible&.edge_count.to_i,
                     visible_external_refs: visible&.nodes&.map(&:external_ref) || [],
                     visibility_applied: !visible.nil?)
        end

        def field(value, key)
          return value[key] || value[key.to_s] if value.is_a?(Hash)
          return value.public_send(key) if value.respond_to?(key)
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        def elapsed_ms(started) = ((monotonic - started) * 1_000).round(3)
      end
    end
  end
end
