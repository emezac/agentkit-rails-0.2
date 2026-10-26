# frozen_string_literal: true

module Agentkit
  module Knowledge
    module Backends
      class Failure < Error; end
      class Unsupported < Failure; end

      # Exact Boolean-semiring rank-2 tensors. No learned weights, floats or GPU.
      class BooleanTensor
        attr_reader :descriptor

        def initialize(max_domain: 128, max_cells: 1_000_000, **limits)
          Engine.new(**limits)
          unless max_domain.is_a?(Integer) && max_domain.between?(1, 128) && max_cells.is_a?(Integer) && max_cells.between?(1, 1_000_000)
            raise InvalidContract, "invalid tensor resource bounds"
          end
          @limits = Engine::DEFAULT_LIMITS.merge(limits).freeze
          @max_domain, @max_cells = max_domain, max_cells
          @descriptor = Boundary.data(name: "boolean_tensor", version: "1", max_domain: max_domain,
            max_cells: max_cells, limits: @limits)
          freeze
        end

        def run(snapshot)
          raise InvalidContract, "expected Snapshot" unless snapshot.is_a?(Snapshot)
          types = snapshot.ontology.data.fetch("relations").values
          unless types.all? { |t| t.size == 2 && t[0] == t[1] } && types.uniq.size == 1
            raise Unsupported, "tensor backend requires binary relations on one shared domain"
          end
          rules = snapshot.rules.map do |rule|
            head, body = rule.head, rule.body
            variables = (body + [head]).all? { |atom| atom.terms.all? { |t| t.is_a?(Hash) } }
            copy = body.size == 1 && head.terms == body[0].terms && head.variables.uniq.size == 2
            join = body.size == 2 && body[0].variables.size == 2 && body[1].variables.size == 2 &&
                   body[0].terms[1] == body[1].terms[0] && head.terms == [body[0].terms[0], body[1].terms[1]] &&
                   body.flat_map(&:variables).uniq.size == 3
            raise Unsupported, "unsupported tensor rule shape" unless variables && (copy || join)
            [rule, copy ? "copy" : "join"]
          end
          domain = snapshot.active_facts.flat_map { |fact| fact.data.fetch("values") }.uniq.sort_by { |v| JSON.generate(v) }
          if domain.size > @max_domain || types.size * domain.size**2 > @max_cells
            raise Unsupported, "tensor domain or matrix cell bound exceeded"
          end
          TensorEvaluation.new(snapshot, rules, domain, @limits).run
        end
      end

      class TensorEvaluation
        def initialize(snapshot, rules, domain, limits)
          @snapshot, @rules, @domain, @limits = snapshot, rules, domain, limits
          @index = domain.each_with_index.to_h
          @matrices = snapshot.ontology.data.fetch("relations").keys.to_h { |name| [name, Array.new(domain.size) { Array.new(domain.size, false) }] }
          @nodes, @steps, @iterations = {}, 0, 0
        end

        def run
          reason = nil
          begin
            @snapshot.active_facts.each do |fact|
              insert(fact.data.fetch("relation"), fact.data.fetch("values"),
                "kind" => "observation", "assertion_id" => fact.data.fetch("id"), "assertion_digest" => fact.digest)
            end
            loop do
              raise Engine::Limit, "max_iterations" if @iterations >= @limits.fetch(:max_iterations)
              @iterations += 1
              before = @nodes.size
              @rules.each { |rule, kind| apply(rule, kind) }
              break if before == @nodes.size
            end
          rescue Engine::Limit => error
            reason = error.message
          end
          Result.new(snapshot: @snapshot, nodes: @nodes, complete: reason.nil?, reason: reason,
            iterations: @iterations, steps: @steps, limits: @limits.transform_keys(&:to_s))
        end

        private

        def tick!
          raise Engine::Limit, "max_steps" if @steps >= @limits.fetch(:max_steps)
          @steps += 1
        end

        def insert(relation, values, witness)
          key = Result.key(relation, values)
          return if @nodes.key?(key)
          raise Engine::Limit, "max_facts" if @nodes.size >= @limits.fetch(:max_facts)
          @nodes[key] = { "relation" => relation, "values" => values, "witness" => witness }
          @matrices.fetch(relation)[@index.fetch(values[0])][@index.fetch(values[1])] = true
        end

        def apply(rule, kind)
          tick!
          left = @matrices.fetch(rule.body[0].relation).map(&:dup)
          right = kind == "join" ? @matrices.fetch(rule.body[1].relation).map(&:dup) : nil
          @domain.each_with_index do |x, i|
            @domain.each_with_index do |y, j|
              tick!
              next unless left[i][j]
              bindings = rule.body[0].variables.zip([x, y]).to_h
              if kind == "copy"
                derive(rule, bindings)
              else
                @domain.each_with_index do |z, k|
                  tick!
                  next unless right[j][k]
                  derive(rule, bindings.merge(rule.body[1].variables[1] => z))
                end
              end
            end
          end
        end

        def derive(rule, bindings)
          insert(rule.head.relation, rule.head.ground(bindings),
            "kind" => "derived", "rule_id" => rule.data.fetch("id"), "rule_digest" => rule.digest,
            "bindings" => bindings, "premises" => rule.body.map { |atom| Result.key(atom.relation, atom.ground(bindings)) })
        end
      end

      # Adapters execute trusted host code, but their factual outputs are checked.
      # Proof validity alone cannot establish completeness or prove absence.
      class Verified
        attr_reader :descriptor

        def initialize(backend:, name:, version:, fallback: "raise", max_proof_nodes: 100_000, **reference_limits)
          unless backend.respond_to?(:run) && %w[raise ruby].include?(fallback)
            raise InvalidContract, "backend runner and explicit fallback policy required"
          end
          unless max_proof_nodes.is_a?(Integer) && max_proof_nodes.between?(1, 1_000_000)
            raise InvalidContract, "bounded proof verification budget required"
          end
          @max_proof_nodes = max_proof_nodes
          @backend, @fallback = backend, fallback
          @reference = Engine.new(**reference_limits)
          @descriptor = Boundary.data(name: Knowledge.text(name), version: Knowledge.text(version),
            fallback: fallback, verification: "proofs_and_reference_completeness",
            reference_limits: Engine::DEFAULT_LIMITS.merge(reference_limits), max_proof_nodes: max_proof_nodes,
            adapter: backend.respond_to?(:descriptor) ? backend.descriptor : nil)
          freeze
        end

        def run(snapshot)
          raise InvalidContract, "expected Snapshot" unless snapshot.is_a?(Snapshot)
          begin
            candidate = @backend.run(snapshot)
            validate!(snapshot, candidate)
            annotate(snapshot, candidate, "candidate", nil)
          rescue StandardError => error
            raise Failure, "backend verification failed (#{error.class})" unless @fallback == "ruby"
            annotate(snapshot, @reference.run(snapshot), "ruby_fallback", error.class.name)
          end
        end

        private

        def validate!(snapshot, candidate)
          unless candidate.is_a?(Result) && candidate.snapshot.digest == snapshot.digest &&
                 candidate.data.fetch("snapshot_digest") == snapshot.digest && [true, false].include?(candidate.complete?)
            raise Failure, "backend returned unbound result"
          end
          nodes = candidate.data.fetch("nodes")
          unless nodes.is_a?(Hash) && nodes.size <= 20_000 && JSON.generate(candidate.to_h).bytesize <= 16 * 1024 * 1024
            raise Failure, "oversized backend result"
          end
          checker = ProofChecker.new
          proof_nodes = 0
          nodes.each do |key, node|
            proof = candidate.proof(key)
            proof_nodes += proof.fetch("nodes").size
            raise Failure, "proof verification budget exceeded" if proof_nodes > @max_proof_nodes
            unless key == Result.key(node.fetch("relation"), node.fetch("values")) &&
                   checker.verify(snapshot: snapshot, relation: node.fetch("relation"), values: node.fetch("values"), proof: proof)
              raise Failure, "backend proof rejected"
            end
          end
          return unless candidate.complete?
          reference = @reference.run(snapshot)
          unless reference.complete? && reference.data.fetch("nodes").keys.sort == nodes.keys.sort
            raise Failure, "backend completeness not established"
          end
        end

        def annotate(snapshot, result, execution, failure)
          Result.new(snapshot: snapshot, nodes: result.data.fetch("nodes"), complete: result.complete?,
            reason: result.data.fetch("reason"), iterations: result.data.fetch("iterations"),
            steps: result.data.fetch("steps"), limits: result.data.fetch("limits"),
            backend: { "contract" => descriptor, "execution" => execution, "failure_class" => failure })
        end
      end
    end
  end
end
