# frozen_string_literal: true

module Agentkit
  module Knowledge
    # Explicit finite orders, not field extensions or Galois groups. The relation
    # must already contain every reflexive/transitive pair: no implicit repairs.
    class FiniteOrder < Record
      MAX_ELEMENTS = 64
      attr_reader :elements

      def initialize(name:, version:, elements:, leq:)
        Knowledge.text(name)
        Knowledge.text(version)
        unless elements.is_a?(Array) && elements.size.between?(1, MAX_ELEMENTS) && elements.uniq == elements
          raise InvalidContract, "bounded unique order elements required"
        end
        elements.each { |element| Knowledge.text(element) }
        unless leq.is_a?(Array) && leq.size <= elements.size**2 && leq.uniq == leq &&
               leq.all? { |pair| pair.is_a?(Array) && pair.size == 2 && (pair - elements).empty? }
          raise InvalidContract, "invalid order pairs"
        end
        @elements = Knowledge.copy(elements.sort)
        @pairs = leq.to_h { |pair| [Knowledge.copy(pair), true] }.freeze
        elements.each do |x|
          raise InvalidContract, "order is not reflexive" unless below?(x, x)
          elements.each do |y|
            raise InvalidContract, "order is not antisymmetric" if x != y && below?(x, y) && below?(y, x)
            next unless below?(x, y)
            elements.each do |z|
              raise InvalidContract, "order is not transitive" if below?(y, z) && !below?(x, z)
            end
          end
        end
        payload = { "name" => name, "version" => version, "elements" => @elements, "leq" => leq.sort }
        raise InvalidContract, "order byte limit exceeded" if JSON.generate(payload).bytesize > 1_048_576
        super(payload)
      end

      def below?(left, right)
        unless elements.include?(left) && elements.include?(right)
          raise InvalidContract, "unknown order element"
        end
        @pairs.key?([left, right])
      end
    end

    class GaloisConnection < Record
      attr_reader :concrete, :abstract

      def initialize(name:, version:, concrete:, abstract:, alpha:, gamma:)
        Knowledge.text(name)
        Knowledge.text(version)
        unless concrete.is_a?(FiniteOrder) && abstract.is_a?(FiniteOrder)
          raise InvalidContract, "finite orders required"
        end
        alpha, gamma = Boundary.data(alpha), Boundary.data(gamma)
        [[alpha, concrete, abstract], [gamma, abstract, concrete]].each do |map, from, to|
          unless map.is_a?(Hash) && map.keys.sort == from.elements && map.values.all? { |value| to.elements.include?(value) }
            raise InvalidContract, "total typed abstraction maps required"
          end
        end
        concrete.elements.each do |c|
          abstract.elements.each do |a|
            unless abstract.below?(alpha.fetch(c), a) == concrete.below?(c, gamma.fetch(a))
              raise InvalidContract, "adjunction failed for #{c.inspect}, #{a.inspect}"
            end
          end
        end
        @concrete, @abstract = concrete, abstract
        payload = { "name" => name, "version" => version, "concrete" => concrete.to_h, "abstract" => abstract.to_h,
              "alpha" => alpha, "gamma" => gamma, "verification" => "exhaustive_finite_adjunction",
              "checked_pairs" => concrete.elements.size * abstract.elements.size }
        raise InvalidContract, "abstraction byte limit exceeded" if JSON.generate(payload).bytesize > 1_048_576
        super(payload)
      end

      def abstract_element(element)
        data.fetch("alpha").fetch(element) { raise InvalidContract, "unknown concrete element" }
      end

      def concretize(element)
        data.fetch("gamma").fetch(element) { raise InvalidContract, "unknown abstract element" }
      end

      def compose(next_connection, name:, version:)
        unless next_connection.is_a?(GaloisConnection) && abstract.digest == next_connection.concrete.digest
          raise InvalidContract, "tower intermediate domains differ"
        end
        self.class.new(name: name, version: version, concrete: concrete, abstract: next_connection.abstract,
          alpha: concrete.elements.to_h { |c| [c, next_connection.abstract_element(abstract_element(c))] },
          gamma: next_connection.abstract.elements.to_h { |a| [a, concretize(next_connection.concretize(a))] })
      end

      def self.from_json(json)
        raise InvalidContract, "abstraction exceeds byte limit" unless json.is_a?(String) && json.bytesize <= 1_048_576
        data = JSON.parse(json, max_nesting: 16)
        Snapshot.exact_keys!(data, %w[name version concrete abstract alpha gamma verification checked_pairs])
        orders = %w[concrete abstract].map do |key|
          item = data.fetch(key)
          Snapshot.exact_keys!(item, %w[name version elements leq])
          FiniteOrder.new(**item.transform_keys(&:to_sym))
        end
        connection = new(name: data.fetch("name"), version: data.fetch("version"), concrete: orders[0], abstract: orders[1],
          alpha: data.fetch("alpha"), gamma: data.fetch("gamma"))
        raise InvalidContract, "abstraction certificate mismatch" unless connection.to_h == data
        connection
      rescue JSON::ParserError, KeyError, TypeError, NoMethodError, ArgumentError
        raise InvalidContract, "invalid abstraction document"
      end
    end

    # Checks the abstract transformer against EVERY concrete element, not a few
    # examples. Tables describe semantics; this does not verify arbitrary code.
    class AbstractTransformer < Record
      def initialize(connection:, concrete_map:, abstract_map:)
        raise InvalidContract, "verified connection required" unless connection.is_a?(GaloisConnection)
        concrete_map, abstract_map = Boundary.data(concrete_map), Boundary.data(abstract_map)
        [[concrete_map, connection.concrete], [abstract_map, connection.abstract]].each do |map, order|
          unless map.is_a?(Hash) && map.keys.sort == order.elements && map.values.all? { |v| order.elements.include?(v) }
            raise InvalidContract, "total endomorphism table required"
          end
          order.elements.each do |x|
            order.elements.each do |y|
              if order.below?(x, y) && !order.below?(map.fetch(x), map.fetch(y))
                raise InvalidContract, "transformer is not monotone"
              end
            end
          end
        end
        connection.concrete.elements.each do |c|
          exact = connection.abstract_element(concrete_map.fetch(c))
          approximation = abstract_map.fetch(connection.abstract_element(c))
          raise InvalidContract, "unsound abstract transformer" unless connection.abstract.below?(exact, approximation)
        end
        super("connection_digest" => connection.digest, "concrete_map" => concrete_map,
              "abstract_map" => abstract_map, "checked_elements" => connection.concrete.elements.size,
              "verification" => "exhaustive_monotone_sound_transformer", "authorizes" => false)
      end
    end

    # A verified concrete witness can support an abstract view, but this is not a
    # new observation, a universal fact, or an authorization decision.
    class AbstractionView < Record
      def initialize(connection:, snapshot:, result:, claims:)
        unless connection.is_a?(GaloisConnection) && snapshot.is_a?(Snapshot) && result.is_a?(Result) &&
               result.snapshot.digest == snapshot.digest && result.data.fetch("nodes").is_a?(Hash) && result.data.fetch("nodes").size <= 20_000
          raise InvalidContract, "bound connection, snapshot and result required"
        end
        claims = Boundary.data(claims)
        unless claims.is_a?(Hash) && (claims.keys - connection.concrete.elements).empty?
          raise InvalidContract, "claims must belong to concrete domain"
        end
        witnesses, unresolved, proof_nodes = [], [], 0
        claims.each do |element, claim|
          Snapshot.exact_keys!(claim, %w[relation values])
          answer = result.query(claim.fetch("relation"), *claim.fetch("values"))
          if answer.fetch("status") == "entailed"
            proof_nodes += answer.fetch("proof").fetch("nodes").size
            raise InvalidContract, "abstraction proof budget exceeded" if proof_nodes > 100_000
            unless ProofChecker.new.verify(snapshot: snapshot, relation: claim.fetch("relation"), values: claim.fetch("values"), proof: answer.fetch("proof"))
              raise IntegrityError, "abstraction witness failed concrete proof check"
            end
            witnesses << { "concrete_element" => element, "abstract_element" => connection.abstract_element(element),
                           "claim" => claim, "proof" => answer.fetch("proof") }
          else
            # Do not trust a caller's claim of closure completeness to prove absence.
            unresolved << { "concrete_element" => element, "claim" => claim, "status" => "unproven" }
          end
        end
        @connection = connection
        payload = { "connection_digest" => connection.digest, "snapshot_digest" => snapshot.digest,
                    "result_digest" => result.digest, "claims" => claims, "witnesses" => witnesses,
                    "unresolved" => unresolved, "authorizes" => false, "kind" => "abstraction_view" }
        raise InvalidContract, "abstraction view byte limit" if JSON.generate(payload).bytesize > 16 * 1024 * 1024
        super(payload)
      end

      def query(element)
        @connection.concretize(element) # validate membership even for an empty view
        witnesses = data.fetch("witnesses").select { |w| @connection.abstract.below?(w.fetch("abstract_element"), element) }
        Knowledge.copy("status" => witnesses.empty? ? "unproven" : "witnessed_abstraction",
                       "view_digest" => digest, "authorizes" => false, "witnesses" => witnesses)
      end
    end

    # Generates a CLOSED finite obligation. No user identifiers/code/imports are
    # interpolated; labels are converted to finite indices. No shell is invoked.
    class LeanExport < Record
      def initialize(connection:)
        unless connection.is_a?(GaloisConnection) && connection.concrete.elements.size <= 16 && connection.abstract.elements.size <= 16
          raise InvalidContract, "Lean export requires at most 16 elements per order"
        end
        c, a = connection.concrete, connection.abstract
        source = "import Std\n\nnamespace AgentkitAbstraction\n"
        source += "def cLe (x y : Fin #{c.elements.size}) : Bool := #{order_expression(c)}\n"
        source += "def aLe (x y : Fin #{a.elements.size}) : Bool := #{order_expression(a)}\n"
        source += "def alpha (x : Fin #{c.elements.size}) : Fin #{a.elements.size} := #{map_expression(c, a, connection.data.fetch('alpha'))}\n"
        source += "def gamma (x : Fin #{a.elements.size}) : Fin #{c.elements.size} := #{map_expression(a, c, connection.data.fetch('gamma'))}\n"
        source += "theorem adjunction : ∀ c : Fin #{c.elements.size}, ∀ a : Fin #{a.elements.size}, aLe (alpha c) a = cLe c (gamma a) := by decide\n"
        source += "#print axioms adjunction\nend AgentkitAbstraction\n"
        super("connection_digest" => connection.digest, "source" => source,
              "source_digest" => Digest::SHA256.hexdigest(source), "language" => "Lean4",
              "status" => "exported_not_lean_checked", "authorizes" => false)
      end

      private

      def order_expression(order)
        pairs = order.data.fetch("leq").map { |left, right| "(x.val == #{order.elements.index(left)} && y.val == #{order.elements.index(right)})" }
        pairs.join(" || ")
      end

      def map_expression(from, to, map)
        from.elements.each_with_index.reverse_each.reduce("(0 : Fin #{to.elements.size})") do |tail, (element, index)|
          "if x.val = #{index} then (#{to.elements.index(map.fetch(element))} : Fin #{to.elements.size}) else #{tail}"
        end
      end
    end
  end
end
