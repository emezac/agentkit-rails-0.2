# frozen_string_literal: true

module Agentkit
  # Finite positive Datalog. This namespace has no persistence or LLM dependency.
  module Knowledge
    class Error < StandardError; end
    class InvalidContract < Error; end

    def self.text(value)
      raise InvalidContract, "expected nonempty string" unless value.is_a?(String) && !value.strip.empty?
      value.dup.freeze
    end

    def self.identifier(value)
      value = text(value)
      raise InvalidContract, "invalid identifier" unless /\A[A-Za-z][A-Za-z0-9_]*\z/.match?(value)
      value
    end

    def self.copy(value)
      case value
      when Hash
        raise InvalidContract, "keys must be strings" unless value.keys.all? { |key| key.is_a?(String) }
        value.keys.sort.to_h { |key| [key.dup.freeze, copy(value.fetch(key))] }.freeze
      when Array then value.map { |item| copy(item) }.freeze
      when String then value.dup.freeze
      when Integer, TrueClass, FalseClass, NilClass then value
      else raise InvalidContract, "only JSON strings, integers, booleans, arrays and objects are supported"
      end
    end

    def self.digest(value) = Digest::SHA256.hexdigest(JSON.generate(copy(value)))

    def self.timestamp(value)
      text(value)
      raise InvalidContract, "timestamp requires explicit timezone" unless /(?:Z|[+-]\d{2}:\d{2})\z/.match?(value)
      Time.iso8601(value).utc.iso8601(6)
    rescue ArgumentError
      raise InvalidContract, "invalid ISO8601 timestamp"
    end

    def self.scalar?(value)
      value.is_a?(String) || value.is_a?(Integer) || value == true || value == false
    end

    # Variables are explicit data, never executable Ruby supplied by a model.
    def self.var(name) = copy("var" => identifier(name))

    class Record
      attr_reader :data
      def initialize(data)
        @data = Knowledge.copy(data)
        freeze
      end
      def to_h = data
      def digest = Knowledge.digest(data)
    end

    class Atom < Record
      def initialize(relation:, terms:)
        Knowledge.identifier(relation)
        raise InvalidContract, "terms must be an array" unless terms.is_a?(Array)
        terms.each do |term|
          next if Knowledge.scalar?(term)
          unless term.is_a?(Hash) && term.keys == ["var"]
            raise InvalidContract, "term must be a scalar or Knowledge.var"
          end
          Knowledge.identifier(term.fetch("var"))
        end
        super("relation" => relation, "terms" => terms)
      end
      def relation = data.fetch("relation")
      def terms = data.fetch("terms")
      def variables = terms.grep(Hash).map { |term| term.fetch("var") }
      def ground(bindings)
        terms.map { |term| term.is_a?(Hash) ? bindings.fetch(term.fetch("var")) : term }
      end
    end

    class Ontology < Record
      PRIMITIVES = %w[string integer boolean].freeze
      # Entity domains are nominal string identifiers, e.g. Order, Customer.
      def initialize(name:, version:, entities: [], relations:)
        Knowledge.identifier(name)
        Knowledge.text(version)
        raise InvalidContract, "entities must be unique" unless entities.is_a?(Array) && entities.uniq == entities
        entities.each { |entity| Knowledge.identifier(entity) }
        raise InvalidContract, "entity shadows primitive" unless (entities & PRIMITIVES).empty?
        raise InvalidContract, "relations must be a nonempty hash" unless relations.is_a?(Hash) && !relations.empty?
        relations.each do |relation, types|
          Knowledge.identifier(relation)
          unless types.is_a?(Array) && !types.empty? && types.all? { |type| (PRIMITIVES + entities).include?(type) }
            raise InvalidContract, "unknown domain or empty arity: #{relation}"
          end
        end
        super("name" => name, "version" => version, "entities" => entities.sort, "relations" => relations)
      end

      def types(relation)
        data.fetch("relations").fetch(relation) { raise InvalidContract, "unknown relation: #{relation}" }
      end

      def validate_tuple!(relation, values)
        domains = types(relation)
        raise InvalidContract, "arity mismatch: #{relation}" unless values.is_a?(Array) && values.size == domains.size
        domains.zip(values).each do |domain, value|
          valid = case domain
                  when "integer" then value.is_a?(Integer)
                  when "boolean" then value == true || value == false
                  when "string" then value.is_a?(String)
                  else value.is_a?(String) && !value.strip.empty?
                  end
          raise InvalidContract, "domain mismatch: #{relation}/#{domain}" unless valid
        end
        true
      end

      def validate_rule!(rule)
        bindings = {}
        (rule.body + [rule.head]).each do |atom|
          domains = types(atom.relation)
          raise InvalidContract, "rule arity mismatch" unless atom.terms.size == domains.size
          domains.zip(atom.terms).each do |domain, term|
            if term.is_a?(Hash)
              variable = term.fetch("var")
              raise InvalidContract, "variable crosses nominal domains" if bindings.key?(variable) && bindings[variable] != domain
              bindings[variable] = domain
            else
              # Validate constants using the same domain checks as facts.
              probe = Ontology.new(name: "Constant", version: "1", entities: data.fetch("entities"), relations: { "Value" => [domain] })
              probe.validate_tuple!("Value", [term])
            end
          end
        end
        true
      end
    end

    class Assertion < Record
      def initialize(id:, scope:, relation:, values:, source:, source_version:, observed_at:,
                     valid_from:, valid_until: nil, kind: "observation")
        [id, scope, source, source_version].each { |value| Knowledge.text(value) }
        Knowledge.identifier(relation)
        unless %w[observation hypothesis].include?(kind) && values.is_a?(Array) && values.all? { |value| Knowledge.scalar?(value) }
          raise InvalidContract, "invalid assertion"
        end
        from = Knowledge.timestamp(valid_from)
        ending = valid_until && Knowledge.timestamp(valid_until)
        raise InvalidContract, "empty validity interval" if ending && ending <= from
        super("id" => id, "scope" => scope, "relation" => relation, "values" => values,
              "source" => source, "source_version" => source_version,
              "observed_at" => Knowledge.timestamp(observed_at), "valid_from" => from,
              "valid_until" => ending, "kind" => kind)
      end
      def active?(at)
        data.fetch("observed_at") <= at && data.fetch("valid_from") <= at &&
          (!data["valid_until"] || at < data["valid_until"])
      end
    end

    class Rule < Record
      attr_reader :head, :body
      def initialize(id:, version:, head:, body:, approved_by:, approved_at:)
        [id, version, approved_by].each { |value| Knowledge.text(value) }
        unless head.is_a?(Atom) && body.is_a?(Array) && !body.empty? && body.all? { |atom| atom.is_a?(Atom) }
          raise InvalidContract, "rule requires head and nonempty positive body"
        end
        unless (head.variables - body.flat_map(&:variables)).empty?
          raise InvalidContract, "head variables must occur in body"
        end
        @head, @body = head, body.dup.freeze
        super("id" => id, "version" => version, "head" => head.to_h, "body" => body.map(&:to_h),
              "approved_by" => approved_by, "approved_at" => Knowledge.timestamp(approved_at))
      end
    end

    class Snapshot < Record
      attr_reader :ontology, :facts, :rules
      MAX_FACTS = 10_000
      MAX_RULES = 256
      MAX_BYTES = 4 * 1024 * 1024

      # Deserialize only data. Constructors revalidate every contract; no eval,
      # constantization, callbacks or implicit trust in an imported digest.
      def self.from_json(json)
        unless json.is_a?(String) && json.bytesize <= MAX_BYTES
          raise InvalidContract, "snapshot byte limit exceeded"
        end
        data = JSON.parse(json, max_nesting: 32)
        exact_keys!(data, %w[schema_version ontology scope at facts rules])
        raise InvalidContract, "unsupported schema version" unless data.fetch("schema_version") == 1
        ontology = data.fetch("ontology")
        exact_keys!(ontology, %w[name version entities relations])
        ontology = Ontology.new(**ontology.transform_keys(&:to_sym))
        facts = data.fetch("facts").map do |fact|
          exact_keys!(fact, %w[id scope relation values source source_version observed_at valid_from valid_until kind])
          Assertion.new(**fact.transform_keys(&:to_sym))
        end
        rules = data.fetch("rules").map do |rule|
          exact_keys!(rule, %w[id version head body approved_by approved_at])
          atom = lambda do |item|
            exact_keys!(item, %w[relation terms])
            Atom.new(**item.transform_keys(&:to_sym))
          end
          Rule.new(id: rule.fetch("id"), version: rule.fetch("version"),
                   head: atom.call(rule.fetch("head")), body: rule.fetch("body").map(&atom),
                   approved_by: rule.fetch("approved_by"), approved_at: rule.fetch("approved_at"))
        end
        new(ontology: ontology, scope: data.fetch("scope"), at: data.fetch("at"), facts: facts, rules: rules)
      rescue JSON::ParserError, KeyError, TypeError, NoMethodError, ArgumentError => error
        raise InvalidContract, "invalid snapshot: #{error.class}"
      end

      def self.exact_keys!(value, keys)
        unless value.is_a?(Hash) && value.keys.sort == keys.sort
          raise InvalidContract, "unexpected contract fields"
        end
      end

      def initialize(ontology:, scope:, at:, facts:, rules:)
        raise InvalidContract, "expected Ontology" unless ontology.is_a?(Ontology)
        Knowledge.text(scope)
        at = Knowledge.timestamp(at)
        unless facts.is_a?(Array) && facts.size <= MAX_FACTS && facts.all? { |fact| fact.is_a?(Assertion) } &&
               rules.is_a?(Array) && rules.size <= MAX_RULES && rules.all? { |rule| rule.is_a?(Rule) }
          raise InvalidContract, "invalid or oversized snapshot collections"
        end
        [facts, rules].each do |records|
          ids = records.map { |record| record.data.fetch("id") }
          raise InvalidContract, "duplicate record ids" unless ids.uniq == ids
        end
        facts.each do |fact|
          raise InvalidContract, "scope mismatch" unless fact.data.fetch("scope") == scope
          raise InvalidContract, "hypotheses cannot be premises" unless fact.data.fetch("kind") == "observation"
          ontology.validate_tuple!(fact.data.fetch("relation"), fact.data.fetch("values"))
        end
        rules.each do |rule|
          raise InvalidContract, "rule was not approved at snapshot time" if rule.data.fetch("approved_at") > at
          raise InvalidContract, "rule body too large" if rule.body.size > 16
          ontology.validate_rule!(rule)
        end
        @ontology = ontology
        @facts = facts.sort_by { |fact| fact.data.fetch("id") }.freeze
        @rules = rules.sort_by { |rule| rule.data.fetch("id") }.freeze
        payload = { "schema_version" => 1, "ontology" => ontology.to_h, "scope" => scope, "at" => at,
                    "facts" => @facts.map(&:to_h), "rules" => @rules.map(&:to_h) }
        raise InvalidContract, "snapshot byte limit exceeded" if JSON.generate(payload).bytesize > MAX_BYTES
        super(payload)
      end
      def active_facts = facts.select { |fact| fact.active?(data.fetch("at")) }
    end
  end
end
