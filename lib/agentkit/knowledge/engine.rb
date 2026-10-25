# frozen_string_literal: true

module Agentkit
  module Knowledge
    class Engine
      DEFAULT_LIMITS = { max_iterations: 100, max_steps: 100_000, max_facts: 20_000 }.freeze
      class Limit < StandardError; end

      def initialize(**limits)
        raise InvalidContract, "unknown limit" unless (limits.keys - DEFAULT_LIMITS.keys).empty?
        @limits = DEFAULT_LIMITS.merge(limits).freeze
        unless @limits.values.all? { |value| value.is_a?(Integer) && value.positive? }
          raise InvalidContract, "limits must be positive integers"
        end
      end

      def run(snapshot)
        raise InvalidContract, "expected Snapshot" unless snapshot.is_a?(Snapshot)
        # Runtime state belongs to this invocation; instances may be reused.
        Evaluation.new(snapshot, @limits).run
      end

      class Evaluation
        def initialize(snapshot, limits)
          @snapshot, @limits = snapshot, limits
          @nodes, @relations = {}, Hash.new { |hash, key| hash[key] = [] }
          @steps, @iterations = 0, 0
        end

        def run
          reason = nil
          begin
            @snapshot.active_facts.each do |fact|
              insert(fact.data.fetch("relation"), fact.data.fetch("values"),
                     "kind" => "observation", "assertion_id" => fact.data.fetch("id"), "assertion_digest" => fact.digest)
            end
            loop do
              raise Limit, "max_iterations" if @iterations >= @limits.fetch(:max_iterations)
              @iterations += 1
              before = @nodes.size
              @snapshot.rules.each do |rule|
                tick!
                match(rule.body, 0, {}, []) do |bindings, premises|
                  insert(rule.head.relation, rule.head.ground(bindings),
                         "kind" => "derived", "rule_id" => rule.data.fetch("id"),
                         "rule_digest" => rule.digest, "bindings" => bindings, "premises" => premises)
                end
              end
              break if @nodes.size == before
            end
          rescue Limit => error
            reason = error.message
          end
          Result.new(snapshot: @snapshot, nodes: @nodes, complete: reason.nil?, reason: reason,
                     iterations: @iterations, steps: @steps, limits: @limits.transform_keys(&:to_s))
        end

        private

        def tick!
          raise Limit, "max_steps" if @steps >= @limits.fetch(:max_steps)
          @steps += 1
        end

        def insert(relation, values, witness)
          key = Result.key(relation, values)
          return if @nodes.key?(key)
          raise Limit, "max_facts" if @nodes.size >= @limits.fetch(:max_facts)
          @nodes[key] = { "relation" => relation, "values" => values, "witness" => witness }
          @relations[relation] << key
        end

        def match(body, index, bindings, premises, &block)
          if index == body.size
            yield bindings, premises
            return
          end
          atom = body[index]
          # Snapshot the candidates: derived rows are consumed by a later pass.
          @relations[atom.relation].dup.each do |key|
            tick!
            candidate = bindings.dup
            matches = atom.terms.zip(@nodes.fetch(key).fetch("values")).all? do |term, value|
              if term.is_a?(Hash)
                name = term.fetch("var")
                if candidate.key?(name)
                  candidate[name] == value
                else
                  candidate[name] = value
                  true
                end
              else
                term == value
              end
            end
            match(body, index + 1, candidate, premises + [key], &block) if matches
          end
        end
      end
    end

    class Result < Record
      attr_reader :snapshot
      def self.key(relation, values) = JSON.generate([relation, values])

      def initialize(snapshot:, nodes:, complete:, reason:, iterations:, steps:, limits:)
        @snapshot = snapshot
        super("schema_version" => 1, "snapshot_digest" => snapshot.digest,
              "complete" => complete, "reason" => reason, "iterations" => iterations,
              "steps" => steps, "limits" => limits, "nodes" => nodes)
      end

      def complete? = data.fetch("complete")

      # A bounded run may prove a positive claim, but absence is inconclusive.
      def query(relation, *values)
        snapshot.ontology.validate_tuple!(relation, values)
        key = self.class.key(relation, values)
        present = data.fetch("nodes").key?(key)
        Knowledge.copy("status" => present ? "entailed" : (complete? ? "not_entailed" : "incomplete"),
                       "snapshot_digest" => snapshot.digest, "result_digest" => digest,
                       "closure_complete" => complete?, "proof" => present ? proof(key) : nil)
      end

      # One deterministic witness per tuple. An acyclic DAG, not a list of all rules.
      def proof(key)
        nodes, pending = {}, [key]
        until pending.empty?
          current = pending.pop
          next if nodes.key?(current)
          node = data.fetch("nodes").fetch(current)
          nodes[current] = node
          pending.concat(node.fetch("witness").fetch("premises", []))
        end
        Knowledge.copy("root" => key, "nodes" => nodes)
      end
    end

    # Checks a detached derivation against authoritative snapshot inputs. It does
    # not trust an LLM's status, rule text or a claimed snapshot digest.
    class ProofChecker
      def verify(snapshot:, relation:, values:, proof:)
        return false unless snapshot.is_a?(Snapshot) && proof.is_a?(Hash)
        snapshot.ontology.validate_tuple!(relation, values)
        root = Result.key(relation, values)
        return false unless proof["root"] == root && proof["nodes"].is_a?(Hash)
        nodes = proof.fetch("nodes")
        return false if nodes.size > 20_000 || JSON.generate(proof).bytesize > 16 * 1024 * 1024
        facts = snapshot.active_facts.to_h { |fact| [fact.data.fetch("id"), fact] }
        rules = snapshot.rules.to_h { |rule| [rule.data.fetch("id"), rule] }
        checked, visiting, stack = {}, {}, [[root, false]]
        until stack.empty?
          key, expanded = stack.pop
          next if checked[key]
          node = nodes.fetch(key)
          return false unless Result.key(node.fetch("relation"), node.fetch("values")) == key
          snapshot.ontology.validate_tuple!(node.fetch("relation"), node.fetch("values"))
          witness = node.fetch("witness")
          case witness.fetch("kind")
          when "observation"
            fact = facts.fetch(witness.fetch("assertion_id"))
            return false unless fact.digest == witness.fetch("assertion_digest") &&
              fact.data.fetch("relation") == node.fetch("relation") && fact.data.fetch("values") == node.fetch("values")
            checked[key] = true
          when "derived"
            rule = rules.fetch(witness.fetch("rule_id"))
            bindings, premises = witness.fetch("bindings"), witness.fetch("premises")
            return false unless rule.digest == witness.fetch("rule_digest") && bindings.is_a?(Hash) && premises.is_a?(Array)
            return false unless bindings.keys.sort == rule.body.flat_map(&:variables).uniq.sort
            return false unless rule.head.relation == node.fetch("relation") && rule.head.ground(bindings) == node.fetch("values")
            return false unless premises.size == rule.body.size
            rule.body.zip(premises).each do |atom, premise|
              return false unless Result.key(atom.relation, atom.ground(bindings)) == premise
            end
            if expanded
              return false unless premises.all? { |premise| checked[premise] }
              checked[key] = true
              visiting.delete(key)
            else
              return false if visiting[key]
              visiting[key] = true
              stack << [key, true]
              premises.reverse_each { |premise| stack << [premise, false] }
            end
          else return false
          end
        end
        checked.size == nodes.size
      rescue InvalidContract, KeyError, TypeError, NoMethodError, ArgumentError, JSON::GeneratorError
        false
      end
    end
  end
end
