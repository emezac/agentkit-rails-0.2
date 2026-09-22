# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

module Agentkit
  # Bounded, replay-first exploration inspired by Dream-RSI. AgentKit adapts
  # the controller that allocates discovery work; it does not mutate the
  # underlying agent, evaluator, execution interface, or its own limits.
  module Exploration
    ROOT_ID = "root"
    API_VERSION = "1.0"
    SCHEMA_VERSION = 2
    RECOVERABLE_FAILURES = %w[compile shape layout resource implementation timeout].freeze

    class Node
      attr_reader :id, :parent_id, :sequence, :score, :status, :failure_class,
                  :artifact_digest, :diagnostics, :metadata, :created_at

      def initialize(id:, parent_id:, sequence:, score: nil, status: "ok", failure_class: nil,
                     artifact_digest: nil, diagnostics: {}, metadata: {}, created_at: Time.now.utc)
        @id = id.to_s
        @parent_id = parent_id&.to_s
        @sequence = Integer(sequence)
        @score = score.nil? ? nil : finite_float(score, "node score")
        @status = status.to_s
        @failure_class = failure_class&.to_s
        @artifact_digest = artifact_digest&.to_s
        @diagnostics = deep_freeze(diagnostics || {})
        @metadata = deep_freeze(metadata || {})
        @created_at = created_at.is_a?(String) ? Time.parse(created_at) : created_at
        validate!
        freeze
      end

      def root? = id == ROOT_ID
      def successful? = !root? && status == "ok"

      def recoverable?
        return true if metadata["recoverable"] == true || metadata[:recoverable] == true

        RECOVERABLE_FAILURES.any? { |token| failure_class.to_s.downcase.include?(token) }
      end

      def to_h
        { id: id, parent_id: parent_id, sequence: sequence, score: score, status: status,
          failure_class: failure_class, artifact_digest: artifact_digest,
          diagnostics: diagnostics, metadata: metadata, created_at: created_at.utc.iso8601(6) }
      end

      private

      def validate!
        raise ConfigurationError, "exploration node id is required" if id.empty?
        if root?
          raise ConfigurationError, "exploration root cannot have a parent or score" if parent_id || score
        elsif parent_id.to_s.empty? || (successful? && score.nil?)
          raise ConfigurationError, "successful exploration nodes need a parent and finite score"
        end
      end

      def finite_float(value, label)
        number = Float(value)
        raise ConfigurationError, "#{label} must be finite" unless number.finite?

        number
      rescue ArgumentError, TypeError
        raise ConfigurationError, "#{label} must be numeric"
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, nested| key.freeze; deep_freeze(nested) }.freeze
        when Array then value.each { |nested| deep_freeze(nested) }.freeze
        else value.freeze
        end
      end
    end

    class World
      attr_reader :id, :tenant_key, :account_id, :objective_digest, :policy_name,
                  :policy_version, :policy_digest, :evaluator_digest, :bounds, :nodes,
                  :rounds, :status, :stop_reason, :created_at, :completed_at, :metadata,
                  :evaluator_manifest, :generator_digest, :generator_manifest,
                  :schema_version

      def initialize(id:, objective_digest:, policy_name:, policy_version:, policy_digest:,
                     evaluator_digest:, bounds:, nodes:, rounds:, status:, stop_reason:,
                     tenant_key: "__global__", account_id: nil, created_at: Time.now.utc,
                     completed_at: Time.now.utc, metadata: {}, evaluator_manifest: {},
                     generator_digest: nil, generator_manifest: {},
                     schema_version: SCHEMA_VERSION)
        @schema_version = Integer(schema_version)
        @id = id.to_s
        @tenant_key = tenant_key.to_s
        @account_id = account_id
        @objective_digest = objective_digest.to_s
        @policy_name = policy_name.to_s
        @policy_version = policy_version.to_s
        @policy_digest = policy_digest.to_s
        @evaluator_digest = evaluator_digest.to_s
        @evaluator_manifest = deep_freeze(stringify(evaluator_manifest || {}))
        @generator_digest = generator_digest&.to_s
        @generator_manifest = deep_freeze(stringify(generator_manifest || {}))
        @bounds = deep_freeze(stringify(bounds || {}))
        @nodes = Array(nodes).dup.freeze
        @rounds = Integer(rounds)
        @status = status.to_s
        @stop_reason = stop_reason.to_s
        @created_at = parse_time(created_at)
        @completed_at = parse_time(completed_at)
        @metadata = deep_freeze(stringify(metadata || {}))
        validate!
        freeze
      end

      def best_score = nodes.reject(&:root?).filter_map(&:score).max
      def node_count = nodes.count { |node| !node.root? }
      def root = nodes.find(&:root?)
      def find(node_id) = nodes.find { |node| node.id == node_id.to_s }
      def children_of(node_id) = nodes.select { |node| node.parent_id == node_id.to_s }.sort_by(&:sequence)

      def digest
        Exploration.digest_for(to_h.reject { |key, _| %i[created_at completed_at].include?(key) })
      end

      def to_h
        payload = { schema_version: schema_version, id: id, tenant_key: tenant_key, account_id: account_id,
          objective_digest: objective_digest, policy_name: policy_name,
          policy_version: policy_version, policy_digest: policy_digest,
          evaluator_digest: evaluator_digest, bounds: bounds, nodes: nodes.map(&:to_h),
          rounds: rounds, status: status, stop_reason: stop_reason,
          created_at: created_at.utc.iso8601(6), completed_at: completed_at&.utc&.iso8601(6),
          metadata: metadata, evaluator_manifest: evaluator_manifest }
        if schema_version >= 2
          payload[:generator_digest] = generator_digest
          payload[:generator_manifest] = generator_manifest
        end
        payload
      end

      def self.from_h(value)
        attrs = value.to_h.transform_keys(&:to_sym)
        attrs[:id] ||= attrs.delete(:world_id)
        attrs[:nodes] = Array(attrs[:nodes]).map do |node|
          node.is_a?(Node) ? node : Node.new(**node.transform_keys(&:to_sym))
        end
        new(**attrs)
      end

      private

      def validate!
        required = [id, objective_digest, policy_name, policy_version, policy_digest, evaluator_digest]
        unless schema_version.between?(1, SCHEMA_VERSION)
          raise ConfigurationError, "exploration world schema version is unsupported"
        end
        raise ConfigurationError, "exploration world provenance is incomplete" if required.any?(&:empty?)
        raise ConfigurationError, "exploration world tenant is required" if tenant_key.empty?
        unless [objective_digest, policy_digest, evaluator_digest].all? { |value| value.start_with?("sha256:") }
          raise ConfigurationError, "exploration world digests must use sha256"
        end
        raise ConfigurationError, "exploration world must contain exactly one root" unless nodes.count(&:root?) == 1
        ids = nodes.map(&:id)
        raise ConfigurationError, "exploration world has duplicate node ids" unless ids.uniq.size == ids.size
        sequences = nodes.map(&:sequence)
        raise ConfigurationError, "exploration world has duplicate node sequences" unless sequences.uniq.size == sequences.size
        raise ConfigurationError, "exploration node sequences must be non-negative" if sequences.any?(&:negative?)
        raise ConfigurationError, "exploration world has an orphan node" if
          nodes.reject(&:root?).any? { |node| !ids.include?(node.parent_id) }
        raise ConfigurationError, "exploration world is not a forward tree" if
          nodes.reject(&:root?).any? { |node| find(node.parent_id).sequence >= node.sequence }
        max_nodes = Integer(bounds.fetch("max_nodes"))
        max_rounds = Integer(bounds.fetch("max_rounds"))
        max_parallelism = Integer(bounds.fetch("max_parallelism"))
        raise ConfigurationError, "exploration world bounds must be positive" unless
          [max_nodes, max_rounds, max_parallelism].all?(&:positive?)
        raise ConfigurationError, "exploration world counters must be non-negative" if rounds.negative?
        raise ConfigurationError, "exploration world exceeds recorded bounds" if node_count > max_nodes || rounds > max_rounds
        raise ConfigurationError, "exploration world status is invalid" unless %w[queued running completed failed].include?(status)
        if %w[queued running].include?(status)
          raise ConfigurationError, "running exploration world cannot be completed" if completed_at
          if status == "queued" && (generator_digest.to_s.empty? || generator_manifest.empty?)
            raise ConfigurationError, "queued exploration world needs a generator manifest"
          end
        elsif stop_reason.empty? || completed_at.nil?
          raise ConfigurationError, "terminal exploration world needs stop reason and completion time"
        end
      rescue KeyError, ArgumentError, TypeError
        raise ConfigurationError, "exploration world bounds are invalid"
      end

      def stringify(value)
        value.each_with_object({}) { |(key, nested), out| out[key.to_s] = nested }
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, nested| key.freeze; deep_freeze(nested) }.freeze
        when Array then value.each { |nested| deep_freeze(nested) }.freeze
        else value.freeze
        end
      end

      def parse_time(value) = value.is_a?(String) ? Time.parse(value) : value
    end

    # This is the only object a policy receives. It contains the revealed
    # prefix and legal parent ids, never the frozen world's unrevealed nodes.
    class View
      attr_reader :nodes, :legal_actions, :structural_actions, :round,
                  :max_parallelism, :beta, :baseline_score

      def initialize(nodes:, legal_actions:, round:, max_parallelism:, beta:, baseline_score: 0.0,
                     structural_actions: nil)
        @nodes = Array(nodes).dup.freeze
        @legal_actions = Array(legal_actions).map(&:to_s).freeze
        @structural_actions = Array(structural_actions || legal_actions).map(&:to_s).freeze
        @round = round.to_i
        @max_parallelism = max_parallelism.to_i
        @beta = Float(beta)
        @baseline_score = Float(baseline_score)
        freeze
      end

      def node(id) = nodes.find { |candidate| candidate.id == id.to_s }
      def non_root_nodes = nodes.reject(&:root?)
      def best_score = non_root_nodes.filter_map(&:score).max || baseline_score
    end

    PolicySpec = Struct.new(:name, :version, :digest, :policy, keyword_init: true)

    EvaluatorManifest = Struct.new(
      :name, :version, :digest, :source_digest, :input_schema, :output_schema,
      :normalization, :metadata, :implementation, keyword_init: true
    ) do
      def call(candidate)
        Schema.validate!(candidate, input_schema, label: "exploration evaluator input") unless input_schema.empty?
        outcome = implementation.call(candidate)
        Schema.validate!(outcome, output_schema, label: "exploration evaluator output")
        outcome
      end

      def to_h
        { name: name, version: version, digest: digest, source_digest: source_digest,
          input_schema: input_schema, output_schema: output_schema,
          normalization: normalization, metadata: metadata }
      end
    end

    GeneratorManifest = Struct.new(
      :name, :version, :digest, :source_digest, :metadata, :implementation,
      keyword_init: true
    ) do
      def call(**kwargs) = implementation.call(**kwargs)

      def to_h
        { name: name, version: version, digest: digest,
          source_digest: source_digest, metadata: metadata }
      end
    end

    Attempt = Struct.new(
      :id, :world_id, :tenant_key, :account_id, :round_number, :position,
      :parent_node_id, :idempotency_key, :status, :node_id, :score,
      :artifact_digest, :failure_class, :outcome_status, :diagnostics, :metadata,
      :started_at, :completed_at, keyword_init: true
    ) do
      def terminal? = %w[completed failed].include?(status)
      def ambiguous? = status == "execution_unknown"
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end
    ATTEMPT_TRANSITIONS = {
      "pending" => %w[running],
      "running" => %w[completed failed execution_unknown],
      "execution_unknown" => %w[pending completed failed]
    }.freeze

    module Evaluators
      DEFAULT_OUTPUT_SCHEMA = {
        "type" => "object",
        "properties" => { "score" => { "type" => "number" } },
        "required" => ["score"],
        "additionalProperties" => true
      }.freeze
      NORMALIZATIONS = %i[identity relative_to_baseline].freeze

      class Registry
        def initialize = @evaluators = {}

        def register(name, version:, evaluator:, input_schema: {}, output_schema: DEFAULT_OUTPUT_SCHEMA,
                     normalization: :identity, source_digest: nil, metadata: {})
          raise ConfigurationError, "exploration evaluator must respond to #call" unless evaluator.respond_to?(:call)
          normalization = normalization.to_sym
          unless NORMALIZATIONS.include?(normalization)
            raise ConfigurationError, "exploration evaluator normalization must be one of #{NORMALIZATIONS.inspect}"
          end

          key = [name.to_s, version.to_s]
          source = source_digest_for(evaluator, source_digest)
          descriptor = deep_freeze({
            name: key.first, version: key.last, source_digest: source,
            input_schema: Schema.normalize(input_schema), output_schema: Schema.normalize(output_schema),
            normalization: normalization, metadata: Audit.sanitize_payload(metadata)
          })
          manifest = EvaluatorManifest.new(
            **descriptor, digest: Exploration.digest_for(descriptor), implementation: evaluator
          ).freeze
          if (existing = @evaluators[key])
            raise ConfigurationError, "exploration evaluator #{key.join('@')} changed without a version bump" unless
              existing.digest == manifest.digest

            return existing
          end

          @evaluators[key] = manifest
        end

        def fetch(name, version:)
          @evaluators.fetch([name.to_s, version.to_s]) do
            raise ConfigurationError, "exploration evaluator #{name}@#{version} is not registered"
          end
        end

        def clear = @evaluators.clear

        private

        def source_digest_for(evaluator, explicit)
          return normalize_digest(explicit) if explicit

          location = if evaluator.respond_to?(:source_location)
                       evaluator.source_location
                     else
                       evaluator.method(:call).source_location
                     end
          unless location && File.file?(location.first)
            instruction = defined?(RubyVM::InstructionSequence) && RubyVM::InstructionSequence.of(evaluator)
            raise ConfigurationError, "exploration evaluator needs an explicit source_digest" unless instruction

            return Exploration.digest_for(instruction.disasm)
          end

          file, line = location
          Exploration.digest_for(file_digest: Digest::SHA256.file(file).hexdigest,
                                 line: line, implementation: evaluator.class.name.to_s)
        rescue Errno::ENOENT
          instruction = defined?(RubyVM::InstructionSequence) && RubyVM::InstructionSequence.of(evaluator)
          raise ConfigurationError, "exploration evaluator needs an explicit source_digest" unless instruction

          Exploration.digest_for(instruction.disasm)
        end

        def normalize_digest(value)
          string = value.to_s
          string.start_with?("sha256:") ? string : Exploration.digest_for(string)
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, nested| key.freeze; deep_freeze(nested) }.freeze
          when Array then value.each { |nested| deep_freeze(nested) }.freeze
          else value.freeze
          end
        end
      end
    end

    module Generators
      class Registry
        def initialize = @generators = {}

        def register(name, version:, generator:, source_digest: nil, metadata: {})
          raise ConfigurationError, "exploration generator must respond to #call" unless generator.respond_to?(:call)

          key = [name.to_s, version.to_s]
          source = source_digest_for(generator, source_digest)
          descriptor = deep_freeze(
            name: key.first, version: key.last, source_digest: source,
            metadata: Audit.sanitize_payload(metadata)
          )
          manifest = GeneratorManifest.new(
            **descriptor, digest: Exploration.digest_for(descriptor), implementation: generator
          ).freeze
          if (existing = @generators[key])
            unless existing.digest == manifest.digest
              raise ConfigurationError,
                    "exploration generator #{key.join('@')} changed without a version bump"
            end
            return existing
          end

          @generators[key] = manifest
        end

        def fetch(name, version:)
          @generators.fetch([name.to_s, version.to_s]) do
            raise ConfigurationError, "exploration generator #{name}@#{version} is not registered"
          end
        end

        def clear = @generators.clear

        private

        def source_digest_for(generator, explicit)
          return normalize_digest(explicit) if explicit

          location = if generator.respond_to?(:source_location)
                       generator.source_location
                     else
                       generator.method(:call).source_location
                     end
          if location && File.file?(location.first)
            return Exploration.digest_for(file_digest: Digest::SHA256.file(location.first).hexdigest,
                                          line: location.last,
                                          implementation: generator.class.name.to_s)
          end

          instruction = defined?(RubyVM::InstructionSequence) && RubyVM::InstructionSequence.of(generator)
          raise ConfigurationError, "exploration generator needs an explicit source_digest" unless instruction

          Exploration.digest_for(instruction.disasm)
        rescue Errno::ENOENT
          raise ConfigurationError, "exploration generator needs an explicit source_digest"
        end

        def normalize_digest(value)
          string = value.to_s
          string.start_with?("sha256:") ? string : Exploration.digest_for(string)
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, nested| key.freeze; deep_freeze(nested) }.freeze
          when Array then value.each { |nested| deep_freeze(nested) }.freeze
          else value.freeze
          end
        end
      end
    end

    module Policies
      class Registry
        def initialize = @policies = {}

        def register(name, version:, policy: nil, &factory)
          implementation = policy || factory
          raise ConfigurationError, "an exploration policy object or factory is required" unless implementation

          key = [name.to_s, version.to_s]
          descriptor = { name: key.first, version: key.last,
                         implementation: implementation.class.name.to_s }
          @policies[key] = PolicySpec.new(name: key.first, version: key.last,
                                          digest: Exploration.digest_for(descriptor),
                                          policy: implementation)
        end

        def fetch(name, version:)
          spec = @policies.fetch([name.to_s, version.to_s]) do
            raise ConfigurationError, "exploration policy #{name}@#{version} is not registered"
          end
          object = spec.policy.respond_to?(:select) ? spec.policy : spec.policy.call
          raise ConfigurationError, "exploration policy must respond to #select" unless object.respond_to?(:select)

          PolicySpec.new(name: spec.name, version: spec.version, digest: spec.digest, policy: object)
        end

        def clear = @policies.clear
      end

      # Deterministic width/depth/recovery portfolio. Beta is fixed for the
      # whole rollout/replay and changes only the relative priority of roles.
      class Portfolio
        attr_reader :beta

        def initialize(beta: nil)
          @beta = beta.nil? ? Agentkit.config.exploration.default_beta.to_f : Float(beta)
          raise ConfigurationError, "exploration beta must be between 0 and 1" unless @beta.between?(0.0, 1.0)
        end

        def select(view)
          legal = view.legal_actions
          return [] if legal.empty?

          ranked = legal.map { |id| [id, role(id, view), priority(id, view)] }
          chosen = []
          exploration = ranked.select { |(_, role_name, _)| role_name == :exploration }.max_by(&:last)
          recovery = ranked.select { |(_, role_name, _)| role_name == :recovery }.max_by(&:last)
          chosen << exploration if exploration && beta >= 0.3
          chosen << recovery if recovery && beta >= 0.45 && chosen.size < view.max_parallelism
          ranked.sort_by { |id, role_name, score| [-score, role_name.to_s, id] }.each do |candidate|
            break if chosen.size >= view.max_parallelism
            next if chosen.any? { |existing| existing.first == candidate.first }
            next if candidate[1] == :recovery && chosen.any? { |existing| existing[1] == :recovery }

            chosen << candidate
          end
          chosen.map(&:first)
        end

        private

        def role(id, view)
          return :exploration if id == ROOT_ID

          node = view.node(id)
          return :recovery if node&.recoverable?
          return :exploration if metadata_number(node, "novelty", 0.0).positive?

          :exploitation
        end

        def priority(id, view)
          return 0.5 + beta if id == ROOT_ID

          node = view.node(id)
          parent = view.node(node&.parent_id)
          gain = node&.score.to_f - parent&.score.to_f
          novelty = metadata_number(node, "novelty", 0.0)
          recovery = node&.recoverable? ? beta * 0.5 : 0.0
          node&.score.to_f + gain + (novelty * beta) + recovery
        end

        def metadata_number(node, key, fallback)
          Float(node&.metadata&.fetch(key, node&.metadata&.fetch(key.to_sym, fallback)))
        rescue ArgumentError, TypeError
          fallback
        end
      end
    end

    ReplayResult = Struct.new(:world_id, :policy_name, :policy_version, :revealed_node_ids,
                              :best_score, :attempts, :rounds, :parallelism, :score,
                              :stop_reason, :decision_coverage, :unsupported_actions,
                              :unsupported_decisions, keyword_init: true) do
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    Evaluation = Struct.new(:policy_name, :policy_version, :policy_digest, :history_digest,
                            :world_count, :mean_score, :mean_quality, :mean_attempts,
                            :mean_rounds, :mean_parallelism, :mean_coverage,
                            :min_coverage, :unsupported_actions, :replays, keyword_init: true) do
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    StatisticalComparison = Struct.new(
      :metric, :sample_size, :mean_difference, :median_difference,
      :standard_error, :ci_lower, :ci_upper, :confidence_level,
      :bootstrap_superiority_rate, :minimum_effect, :significant,
      :method, :seed_digest, keyword_init: true
    ) do
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    HoldoutSplit = Struct.new(
      :strategy, :training_worlds, :holdout_worlds, :training_digest,
      :holdout_digest, :assignment_digest, keyword_init: true
    ) do
      def to_h
        { strategy: strategy, training_world_count: training_worlds.size,
          holdout_world_count: holdout_worlds.size,
          training_digest: training_digest, holdout_digest: holdout_digest,
          assignment_digest: assignment_digest }
      end
    end

    Recommendation = Struct.new(
      :status, :level, :incumbent, :selected, :evaluations,
      :holdout_evaluations, :pareto_frontier, :holdout, :comparison,
      :requires_review, :auto_promoted, :reason, keyword_init: true
    ) do
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    OperationsSnapshot = Struct.new(
      :generated_at, :world_counts, :attempt_counts, :quotas, :recent_worlds,
      keyword_init: true
    ) do
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    module Pareto
      OBJECTIVES = {
        mean_quality: :maximize,
        mean_attempts: :minimize,
        mean_rounds: :minimize
      }.freeze

      module_function

      def frontier(evaluations, epsilon: 0.0)
        list = Array(evaluations)
        list.reject do |candidate|
          list.any? { |other| !other.equal?(candidate) && dominates?(other, candidate, epsilon) }
        end.sort_by { |evaluation| [evaluation.policy_name, evaluation.policy_version] }
      end

      def dominates?(left, right, epsilon = 0.0)
        comparisons = OBJECTIVES.map do |attribute, direction|
          left_value = Float(left.public_send(attribute))
          right_value = Float(right.public_send(attribute))
          if direction == :maximize
            [left_value >= right_value - epsilon, left_value > right_value + epsilon]
          else
            [left_value <= right_value + epsilon, left_value < right_value - epsilon]
          end
        end
        comparisons.all?(&:first) && comparisons.any?(&:last)
      end
    end

    BetaPlan = Struct.new(:current_beta, :recommended_beta, :reason, :requires_review,
                          :evidence, keyword_init: true) do
      def changed? = current_beta != recommended_beta
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    module Stores
      class Memory
        def initialize
          @worlds = {}
          @attempts = {}
          @leases = {}
          @mutex = Mutex.new
        end

        def save(world, lease_owner: nil)
          @mutex.synchronize do
            existing = @worlds[world.id]
            if existing && existing.tenant_key != world.tenant_key
              raise ConfigurationError, "exploration world id belongs to another tenant"
            end
            lease = @leases[world.id]
            if lease_owner && lease&.fetch(:owner) != lease_owner.to_s
              raise ExplorationInProgress, "exploration world #{world.id} lease ownership changed"
            elsif lease_owner.nil? && existing && lease
              raise ExplorationInProgress, "exploration world #{world.id} requires its lease owner"
            end
            @worlds[world.id] = copy(world)
            copy(world)
          end
        end

        def all(scope: Scope.resolve, include_incomplete: false)
          @mutex.synchronize do
            @worlds.values.select do |world|
              scope.match?(world) && (include_incomplete || world.status == "completed")
            end.map { |world| copy(world) }
          end
        end

        def find(id, scope: Scope.resolve, include_incomplete: false)
          all(scope: scope, include_incomplete: include_incomplete)
            .find { |world| world.id == id.to_s }
        end

        def prepare_attempts(attempts)
          @mutex.synchronize do
            Array(attempts).map do |attempt|
              existing = @attempts.values.find do |candidate|
                candidate.tenant_key == attempt.tenant_key &&
                  candidate.idempotency_key == attempt.idempotency_key
              end
              if existing
                unless same_attempt?(existing, attempt)
                  raise IdempotencyConflict, "exploration attempt key was reused with different arguments"
                end
                next copy(existing)
              end
              @attempts[attempt.id] = copy(attempt)
              copy(attempt)
            end
          end
        end

        def transition_attempt(id, from:, to:, attrs: {}, scope: Scope.resolve)
          @mutex.synchronize do
            attempt = @attempts[id.to_s]
            raise ConfigurationError, "exploration attempt not found" unless attempt && scope.match?(attempt)
            transition_attempt!(attempt, from: from, to: to, attrs: attrs)
            copy(attempt)
          end
        end

        def attempts(world_id, scope: Scope.resolve)
          @mutex.synchronize do
            @attempts.values.select do |attempt|
              attempt.world_id == world_id.to_s && scope.match?(attempt)
            end.sort_by { |attempt| [attempt.round_number, attempt.position] }
             .map { |attempt| copy(attempt) }
          end
        end

        def mark_inflight_unknown(world_id, scope: Scope.resolve)
          @mutex.synchronize do
            @attempts.values.select do |attempt|
              attempt.world_id == world_id.to_s && attempt.status == "running" && scope.match?(attempt)
            end.each do |attempt|
              transition_attempt!(attempt, from: "running", to: "execution_unknown",
                                            attrs: { completed_at: Time.now.utc })
            end
          end
        end

        def acquire_world(world_id, owner:, ttl:, scope: Scope.resolve)
          @mutex.synchronize do
            world = scoped_world!(world_id, scope)
            unless %w[queued running].include?(world.status)
              raise ConfigurationError, "only a queued or running exploration world can be acquired"
            end
            now = Time.now.utc
            lease = @leases[world.id]
            if lease && lease[:expires_at] > now && lease[:owner] != owner.to_s
              raise ExplorationInProgress, "exploration world #{world.id} is already being resumed"
            end

            @leases[world.id] = { owner: owner.to_s, expires_at: now + Float(ttl) }
            copy(world)
          end
        end

        def renew_world(world_id, owner:, ttl:, scope: Scope.resolve)
          @mutex.synchronize do
            world = scoped_world!(world_id, scope)
            lease = @leases[world.id]
            unless lease && lease[:owner] == owner.to_s
              raise ExplorationInProgress, "exploration world #{world.id} lease ownership changed"
            end

            lease[:expires_at] = Time.now.utc + Float(ttl)
            true
          end
        end

        def release_world(world_id, owner:, scope: Scope.resolve)
          @mutex.synchronize do
            world = scoped_world!(world_id, scope)
            lease = @leases[world.id]
            return false unless lease
            unless lease[:owner] == owner.to_s
              raise ExplorationInProgress, "exploration world #{world.id} lease ownership changed"
            end

            @leases.delete(world.id)
            true
          end
        end

        def clear
          @mutex.synchronize { @worlds.clear; @attempts.clear; @leases.clear }
        end

        private

        def transition_attempt!(attempt, from:, to:, attrs:)
          expected = Array(from).map(&:to_s)
          raise ConfigurationError, "exploration attempt is #{attempt.status}, expected #{expected.join(' or ')}" unless
            expected.include?(attempt.status)
          allowed = ATTEMPT_TRANSITIONS.fetch(attempt.status, [])
          raise ConfigurationError, "invalid exploration attempt transition #{attempt.status} -> #{to}" unless
            allowed.include?(to.to_s)

          attempt.status = to.to_s
          attrs.each { |key, value| attempt.public_send("#{key}=", value) }
        end

        def same_attempt?(left, right)
          %i[world_id tenant_key round_number position parent_node_id idempotency_key]
            .all? { |field| left.public_send(field).to_s == right.public_send(field).to_s }
        end

        def scoped_world!(world_id, scope)
          world = @worlds[world_id.to_s]
          raise ConfigurationError, "exploration world not found" unless world && scope.match?(world)

          world
        end

        def copy(value) = Marshal.load(Marshal.dump(value))
      end

      class ActiveRecord
        def save(world, lease_owner: nil)
          Agentkit::ExplorationWorldRecord.transaction do
            row = Agentkit::ExplorationWorldRecord.find_or_initialize_by(world_id: world.id)
            row.lock! if row.persisted?
            if row.persisted? && row.tenant_key != world.tenant_key
              raise ConfigurationError, "exploration world id belongs to another tenant"
            end
            if lease_owner && row.lease_owner != lease_owner.to_s
              raise ExplorationInProgress, "exploration world #{world.id} lease ownership changed"
            elsif lease_owner.nil? && row.persisted? && row.lease_owner.present?
              raise ExplorationInProgress, "exploration world #{world.id} requires its lease owner"
            end
            row.assign_attributes(
              tenant_key: world.tenant_key, account_id: world.account_id,
              objective_digest: world.objective_digest,
              policy_name: world.policy_name, policy_version: world.policy_version,
              policy_digest: world.policy_digest, evaluator_digest: world.evaluator_digest,
              bounds: world.bounds, tree: world.to_h, rounds: world.rounds,
              node_count: world.node_count, best_score: world.best_score,
              status: world.status, stop_reason: world.stop_reason,
              completed_at: world.completed_at, metadata: world.metadata,
              checkpoint_version: world.rounds, last_checkpoint_at: Time.now.utc,
              evaluator_manifest: world.evaluator_manifest
            )
            if row.respond_to?(:generator_digest=)
              row.generator_digest = world.generator_digest
              row.generator_manifest = world.generator_manifest
            end
            row.save!
          end
          world
        end

        def all(scope: Scope.resolve, include_incomplete: false)
          relation = Agentkit::ExplorationWorldRecord.all
          relation = relation.where(tenant_key: scope.tenant_key) if scope.tenant_key
          relation = relation.where(account_id: scope.account_id) if scope.account_id
          relation = relation.where(status: "completed") unless include_incomplete
          relation.order(:created_at).map { |row| World.from_h(row.tree) }
        end

        def find(id, scope: Scope.resolve, include_incomplete: false)
          all(scope: scope, include_incomplete: include_incomplete)
            .find { |world| world.id == id.to_s }
        end

        def prepare_attempts(attempts)
          Agentkit::ExplorationAttemptRecord.transaction do
            Array(attempts).map do |attempt|
              row = Agentkit::ExplorationAttemptRecord.find_by(
                tenant_key: attempt.tenant_key, idempotency_key: attempt.idempotency_key
              )
              if row
                existing = wrap_attempt(row)
                unless same_attempt?(existing, attempt)
                  raise IdempotencyConflict, "exploration attempt key was reused with different arguments"
                end
                next existing
              end
              wrap_attempt(Agentkit::ExplorationAttemptRecord.create!(attempt_attributes(attempt)))
            end
          end
        rescue ::ActiveRecord::RecordNotUnique
          prepare_attempts(attempts)
        end

        def transition_attempt(id, from:, to:, attrs: {}, scope: Scope.resolve)
          Agentkit::ExplorationAttemptRecord.transaction do
            row = attempt_relation(scope).lock.find_by!(attempt_id: id.to_s)
            expected = Array(from).map(&:to_s)
            unless expected.include?(row.status)
              raise ConfigurationError, "exploration attempt is #{row.status}, expected #{expected.join(' or ')}"
            end
            allowed = ATTEMPT_TRANSITIONS.fetch(row.status, [])
            raise ConfigurationError, "invalid exploration attempt transition #{row.status} -> #{to}" unless
              allowed.include?(to.to_s)

            row.update!(attrs.merge(status: to.to_s))
            wrap_attempt(row)
          end
        end

        def attempts(world_id, scope: Scope.resolve)
          attempt_relation(scope).where(world_id: world_id.to_s)
                                 .order(:round_number, :position).map { |row| wrap_attempt(row) }
        end

        def mark_inflight_unknown(world_id, scope: Scope.resolve)
          attempt_relation(scope).where(world_id: world_id.to_s, status: "running")
                                 .update_all(status: "execution_unknown", completed_at: Time.now.utc,
                                             updated_at: Time.now.utc)
        end

        def acquire_world(world_id, owner:, ttl:, scope: Scope.resolve)
          world = nil
          Agentkit::ExplorationWorldRecord.transaction do
            row = world_relation(scope).lock.find_by!(world_id: world_id.to_s)
            unless %w[queued running].include?(row.status)
              raise ConfigurationError, "only a queued or running exploration world can be acquired"
            end
            now = Time.now.utc
            if row.lease_owner.present? && row.lease_expires_at && row.lease_expires_at > now &&
               row.lease_owner != owner.to_s
              raise ExplorationInProgress, "exploration world #{row.world_id} is already being resumed"
            end

            row.update!(lease_owner: owner.to_s, lease_expires_at: now + Float(ttl))
            world = World.from_h(row.tree)
          end
          world
        end

        def renew_world(world_id, owner:, ttl:, scope: Scope.resolve)
          Agentkit::ExplorationWorldRecord.transaction do
            row = world_relation(scope).lock.find_by!(world_id: world_id.to_s)
            unless row.lease_owner == owner.to_s
              raise ExplorationInProgress, "exploration world #{row.world_id} lease ownership changed"
            end

            row.update!(lease_expires_at: Time.now.utc + Float(ttl))
          end
          true
        end

        def release_world(world_id, owner:, scope: Scope.resolve)
          released = false
          Agentkit::ExplorationWorldRecord.transaction do
            row = world_relation(scope).lock.find_by!(world_id: world_id.to_s)
            if row.lease_owner.present?
              unless row.lease_owner == owner.to_s
                raise ExplorationInProgress, "exploration world #{row.world_id} lease ownership changed"
              end

              row.update!(lease_owner: nil, lease_expires_at: nil)
              released = true
            end
          end
          released
        end

        def operations(scope:, limit:)
          worlds = world_relation(scope)
          attempts = attempt_relation(scope)
          world_counts = worlds.group(:status).count.transform_keys(&:to_s)
          attempt_counts = attempts.group(:status).count.transform_keys(&:to_s)
          recent_worlds = worlds.order(created_at: :desc).limit(limit).map do |row|
            { id: row.world_id, status: row.status, policy_name: row.policy_name,
              policy_version: row.policy_version, rounds: row.rounds,
              node_count: row.node_count, best_score: row.best_score&.to_f,
              stop_reason: row.stop_reason.to_s.empty? ? nil : row.stop_reason,
              evaluator_digest: row.evaluator_digest,
              created_at: row.created_at, completed_at: row.completed_at }
          end
          { world_counts: world_counts, attempt_counts: attempt_counts,
            recent_worlds: recent_worlds }
        end

        private

        def world_relation(scope)
          relation = Agentkit::ExplorationWorldRecord.all
          relation = relation.where(tenant_key: scope.tenant_key) if scope.tenant_key
          relation = relation.where(account_id: scope.account_id) if scope.account_id
          relation
        end

        def attempt_relation(scope)
          relation = Agentkit::ExplorationAttemptRecord.all
          relation = relation.where(tenant_key: scope.tenant_key) if scope.tenant_key
          relation = relation.where(account_id: scope.account_id) if scope.account_id
          relation
        end

        def wrap_attempt(row)
          Attempt.new(**Attempt.members.to_h { |field| [field, row.public_send(record_field(field))] })
        end

        def attempt_attributes(attempt)
          attempt.to_h.each_with_object({}) do |(field, value), attributes|
            attributes[record_field(field)] = value
          end
        end

        def record_field(field) = field == :id ? :attempt_id : field

        def same_attempt?(left, right)
          %i[world_id tenant_key round_number position parent_node_id idempotency_key]
            .all? { |field| left.public_send(field).to_s == right.public_send(field).to_s }
        end
      end
    end

    class OnlineRunner
      def initialize(policy_spec:, evaluator_spec:, generator_spec:, store:, scope:,
                     max_rounds:, max_parallelism:, max_nodes:, beta:, baseline_score:,
                     world: nil, world_id: nil)
        unless generator_spec.respond_to?(:call)
          raise ConfigurationError, "exploration generator must respond to #call"
        end

        @policy_spec = policy_spec
        @evaluator_spec = evaluator_spec
        @generator_spec = generator_spec
        @store = store
        @scope = scope
        @max_rounds = max_rounds
        @max_parallelism = max_parallelism
        @max_nodes = max_nodes
        @beta = beta
        @baseline_score = Float(baseline_score)
        @existing_world = world
        @requested_world_id = world_id
        @lease_owner = SecureRandom.uuid
        @lease_acquired = false
        raise ConfigurationError, "exploration baseline score must be finite" unless @baseline_score.finite?
      end

      def run(objective: nil, metadata: {})
        initialize_state(objective, metadata)
        if @existing_world
          restore_state(acquire_lease!)
          checkpoint!(status: "running")
        else
          checkpoint!(status: "running")
          acquire_lease!
        end
        stop_reason = "round_limit"

        while @rounds < @max_rounds && (@nodes.size - 1) < @max_nodes
          legal = online_legal_actions(@nodes)
          view = View.new(nodes: @nodes, legal_actions: legal, round: @rounds,
                          max_parallelism: effective_width(@nodes), beta: @beta,
                          baseline_score: policy_baseline_score)
          round_attempts = attempts_for_round(@rounds)
          handle_ambiguous!(round_attempts)
          if round_attempts.empty?
            batch = Guard.batch!(@policy_spec.policy.select(view), view)
            if batch.empty?
              stop_reason = "policy_stop"
              break
            end
            round_attempts = prepare_attempts(batch)
          end

          execute_attempts(round_attempts, view)
            .sort_by(&:position).each { |attempt| @nodes << node_from(attempt, @nodes.size) }
          @rounds += 1
          checkpoint!(status: "running")
        end
        stop_reason = "node_limit" if (@nodes.size - 1) >= @max_nodes
        world = checkpoint!(status: "completed", stop_reason: stop_reason,
                            completed_at: Time.now.utc)
        release_lease!
        Telemetry.emit("exploration.online.completed",
                       dims: { policy: world.policy_name, policy_version: world.policy_version,
                               status: world.status, stop_reason: world.stop_reason },
                       measures: { rounds: world.rounds, nodes: world.node_count,
                                   best_score: world.best_score })
        world
      rescue ExplorationQuotaExceeded
        world = checkpoint!(status: "completed", stop_reason: "quota_exhausted",
                            completed_at: Time.now.utc)
        best_effort_release_lease! if @lease_acquired
        Telemetry.emit("exploration.online.quota_exhausted",
                       dims: { policy: world.policy_name },
                       measures: { rounds: world.rounds, nodes: world.node_count })
        world
      rescue ReconciliationRequired, ExplorationInProgress
        best_effort_release_lease! if @lease_acquired
        raise
      rescue StandardError => e
        if @world_id && @lease_acquired
          begin
            checkpoint!(status: "failed", stop_reason: "error:#{e.class.name}",
                        completed_at: Time.now.utc)
          ensure
            best_effort_release_lease! if @lease_acquired
          end
        end
        raise
      end

      private

      def initialize_state(objective, metadata)
        if @existing_world
          restore_state(@existing_world)
        else
          @world_id = @requested_world_id || SecureRandom.uuid
          @objective_digest = Exploration.digest_for(objective.to_s)
          @nodes = [Node.new(id: ROOT_ID, parent_id: nil, sequence: 0)]
          @rounds = 0
          @started = Time.now.utc
          @metadata = bounded(metadata)
        end
      end

      def restore_state(world)
        @world_id = world.id
        @objective_digest = world.objective_digest
        @nodes = world.nodes.dup
        @rounds = world.rounds
        @started = world.created_at
        @metadata = world.metadata
      end

      def checkpoint!(status:, stop_reason: nil, completed_at: nil)
        world = @store.save(World.new(
          id: @world_id, tenant_key: @scope.tenant_key || "__global__",
          account_id: @scope.account_id, objective_digest: @objective_digest,
          policy_name: @policy_spec.name, policy_version: @policy_spec.version,
          policy_digest: @policy_spec.digest, evaluator_digest: @evaluator_spec.digest,
          evaluator_manifest: @evaluator_spec.to_h,
          generator_digest: @generator_spec.digest,
          generator_manifest: @generator_spec.to_h,
          bounds: { max_rounds: @max_rounds, max_parallelism: @max_parallelism,
                    max_nodes: @max_nodes, beta: @beta,
                    baseline_score: policy_baseline_score,
                    evaluator_baseline_score: @baseline_score },
          nodes: @nodes, rounds: @rounds, status: status, stop_reason: stop_reason,
          created_at: @started, completed_at: completed_at, metadata: @metadata
        ), lease_owner: @lease_acquired ? @lease_owner : nil)
        renew_lease! if @lease_acquired && status == "running"
        world
      end

      def acquire_lease!
        world = @store.acquire_world(@world_id, owner: @lease_owner,
                                     ttl: Agentkit.config.exploration.resume_lease,
                                     scope: @scope)
        @lease_acquired = true
        world
      end

      def renew_lease!
        @store.renew_world(@world_id, owner: @lease_owner,
                           ttl: Agentkit.config.exploration.resume_lease,
                           scope: @scope)
      end

      def release_lease!
        @store.release_world(@world_id, owner: @lease_owner, scope: @scope)
        @lease_acquired = false
      end

      def best_effort_release_lease!
        release_lease!
      rescue ExplorationInProgress
        @lease_acquired = false
      end

      def online_legal_actions(nodes)
        parents = nodes.reject(&:root?).map(&:parent_id)
        [ROOT_ID] + nodes.reject(&:root?).reject { |node| parents.include?(node.id) }.map(&:id)
      end

      def effective_width(nodes)
        [@max_parallelism, @max_nodes - (nodes.size - 1)].min
      end

      def attempts_for_round(round)
        @store.attempts(@world_id, scope: @scope).select { |attempt| attempt.round_number == round }
      end

      def prepare_attempts(batch)
        attempts = batch.each_with_index.map do |parent_id, position|
          Attempt.new(
            id: SecureRandom.uuid, world_id: @world_id,
            tenant_key: @scope.tenant_key || "__global__", account_id: @scope.account_id,
            round_number: @rounds, position: position, parent_node_id: parent_id,
            idempotency_key: attempt_key(@rounds, position, parent_id), status: "pending",
            diagnostics: {}, metadata: {}
          )
        end
        Quota.reserve!(resource: :attempts, amount: attempts.size,
                       reservation_key: "world:#{@world_id}:round:#{@rounds}", scope: @scope)
        @store.prepare_attempts(attempts)
      end

      def handle_ambiguous!(attempts)
        running = attempts.select { |attempt| attempt.status == "running" }
        if running.any?
          cutoff = Time.now.utc - Float(Agentkit.config.exploration.attempt_stale_after)
          if running.any? { |attempt| attempt.started_at && attempt.started_at > cutoff }
            raise ExplorationInProgress,
                  "exploration world #{@world_id} still has active attempts"
          end

          @store.mark_inflight_unknown(@world_id, scope: @scope)
          Telemetry.emit("exploration.attempt.unknown",
                         dims: { reason: "stale_running_attempt" },
                         measures: { count: running.size })
          attempts = attempts_for_round(@rounds)
        end
        return unless attempts.any?(&:ambiguous?)

        raise ReconciliationRequired,
              "exploration world #{@world_id} has ambiguous attempts; reconcile them before resume"
      end

      def execute_attempts(attempts, view)
        running = attempts.select { |attempt| attempt.status == "pending" }.map do |attempt|
          @store.transition_attempt(attempt.id, from: "pending", to: "running",
                                    attrs: { started_at: Time.now.utc }, scope: @scope)
        end
        jobs = running.map do |attempt|
          Thread.new { attempt_result(attempt, view) }.tap { |thread| thread.report_on_exception = false }
        end
        results = jobs.map(&:value)
        results.each do |attempt, target, attrs, error|
          @store.transition_attempt(attempt.id, from: "running", to: target,
                                    attrs: attrs, scope: @scope)
          if error && !error.is_a?(ConfigurationError)
            Telemetry.emit("exploration.attempt.failed",
                           dims: { error_class: error.class.name }, measures: { count: 1 })
          end
        end
        contract_error = results.filter_map do |(_, _, _, error)|
          error if error.is_a?(ConfigurationError) || error.is_a?(SchemaValidationError)
        end.first
        raise contract_error if contract_error

        finished = attempts_for_round(@rounds)
        unless finished.size == attempts.size && finished.all?(&:terminal?)
          raise ConfigurationError, "exploration round did not reach a durable terminal state"
        end
        finished
      end

      def attempt_result(attempt, view)
        candidate = @generator_spec.call(
          parent: attempt.parent_node_id == ROOT_ID ? nil : view.node(attempt.parent_node_id),
          view: view
        )
        outcome = normalize_outcome(@evaluator_spec.call(candidate))
        [attempt, "completed",
         { node_id: SecureRandom.uuid, score: outcome.fetch(:score),
           artifact_digest: Exploration.digest_for(candidate),
           failure_class: outcome[:failure_class], outcome_status: outcome.fetch(:status, "ok"),
           diagnostics: bounded(outcome[:diagnostics] || {}),
           metadata: bounded(outcome[:metadata] || {}), completed_at: Time.now.utc }, nil]
      rescue StandardError => e
        [attempt, "failed",
         { node_id: SecureRandom.uuid, score: nil, outcome_status: "error",
           artifact_digest: Exploration.digest_for(failed: true, error_class: e.class.name),
           failure_class: e.class.name, diagnostics: { "error_class" => e.class.name },
           metadata: {}, completed_at: Time.now.utc }, e]
      end

      def node_from(attempt, sequence)
        Node.new(id: attempt.node_id, parent_id: attempt.parent_node_id, sequence: sequence,
                 score: attempt.score, status: attempt.outcome_status || "error",
                 failure_class: attempt.failure_class, artifact_digest: attempt.artifact_digest,
                 diagnostics: attempt.diagnostics || {}, metadata: attempt.metadata || {})
      end

      def attempt_key(round, position, parent_id)
        "exploration:#{@world_id}:#{round}:#{position}:#{Exploration.digest_for(parent_id)[0, 24]}"
      end

      def normalize_outcome(value)
        hash = value.to_h.transform_keys(&:to_sym)
        score = Float(hash.fetch(:score))
        raise ConfigurationError, "exploration evaluator score must be finite" unless score.finite?

        normalized = case @evaluator_spec.normalization.to_sym
                     when :identity then score
                     when :relative_to_baseline then score - @baseline_score
                     else
                       raise ConfigurationError, "exploration evaluator normalization is unsupported"
                     end
        hash.merge(score: normalized)
      rescue KeyError, ArgumentError, TypeError
        raise ConfigurationError, "exploration evaluator must return a finite numeric score"
      end

      def policy_baseline_score
        @evaluator_spec.normalization.to_sym == :relative_to_baseline ? 0.0 : @baseline_score
      end

      def bounded(value)
        sanitized = Audit.sanitize_payload(value)
        bytes = JSON.generate(sanitized).bytesize
        return sanitized if bytes <= Agentkit.config.exploration.max_diagnostics_bytes.to_i

        { "truncated" => true, "digest" => Exploration.digest_for(sanitized), "bytes" => bytes }
      end
    end

    module Guard
      module_function

      def batch!(selection, view)
        batch = Array(selection).map(&:to_s)
        raise ConfigurationError, "exploration policy selected duplicate actions" unless batch.uniq.size == batch.size
        raise ConfigurationError, "exploration policy exceeded max_parallelism" if batch.size > view.max_parallelism
        illegal = batch - view.legal_actions
        raise ConfigurationError, "exploration policy selected illegal actions: #{illegal.join(', ')}" if illegal.any?

        batch.freeze
      end
    end

    class Replayer
      def initialize(world:, policy_spec:, max_rounds:, max_parallelism:, beta:,
                     cost_penalty:, parallelism_bonus:)
        @world = world
        @policy_spec = policy_spec
        @max_rounds = max_rounds
        @max_parallelism = max_parallelism
        @beta = beta
        @cost_penalty = cost_penalty
        @parallelism_bonus = parallelism_bonus
      end

      def run
        revealed = [@world.root]
        rounds = 0
        stop_reason = "round_limit"
        supported_opportunities = 0
        total_opportunities = 0
        unsupported_decisions = 0
        while rounds < @max_rounds
          structural = replay_structural_actions(revealed)
          legal = replay_legal_actions(revealed)
          total_opportunities += structural.size
          supported_opportunities += legal.size
          unsupported_decisions += 1 if legal.size < structural.size
          if legal.empty?
            stop_reason = "history_exhausted"
            break
          end
          view = View.new(nodes: revealed, legal_actions: legal, round: rounds,
                          max_parallelism: @max_parallelism, beta: @beta,
                          baseline_score: baseline_score, structural_actions: structural)
          batch = Guard.batch!(@policy_spec.policy.select(view), view)
          if batch.empty?
            stop_reason = "policy_stop"
            break
          end
          batch.each { |parent_id| revealed << next_child(parent_id, revealed) }
          rounds += 1
        end
        attempts = revealed.size - 1
        quality = revealed.reject(&:root?).filter_map(&:score).max || baseline_score
        parallelism = attempts.zero? ? 0.0 : attempts.to_f / [rounds, 1].max
        score = quality - (@cost_penalty * attempts) + (@parallelism_bonus * parallelism)
        coverage = total_opportunities.zero? ? 1.0 : supported_opportunities.to_f / total_opportunities
        ReplayResult.new(world_id: @world.id, policy_name: @policy_spec.name,
                         policy_version: @policy_spec.version,
                         revealed_node_ids: revealed.map(&:id), best_score: quality,
                         attempts: attempts, rounds: rounds, parallelism: parallelism,
                         score: score, stop_reason: stop_reason,
                         decision_coverage: coverage.round(6),
                         unsupported_actions: total_opportunities - supported_opportunities,
                         unsupported_decisions: unsupported_decisions)
      end

      private

      def baseline_score = Float(@world.bounds.fetch("baseline_score", 0.0))

      def replay_legal_actions(revealed)
        revealed_ids = revealed.map(&:id)
        replay_structural_actions(revealed).select do |parent_id|
          @world.children_of(parent_id).any? { |child| !revealed_ids.include?(child.id) }
        end
      end

      def replay_structural_actions(revealed)
        revealed_ids = revealed.map(&:id)
        revealed_parents = revealed.reject(&:root?).map(&:parent_id)
        [ROOT_ID] + revealed.reject(&:root?).reject do |node|
          revealed_parents.include?(node.id) || !revealed_ids.include?(node.id)
        end.map(&:id)
      end

      def next_child(parent_id, revealed)
        ids = revealed.map(&:id)
        @world.children_of(parent_id).find { |child| !ids.include?(child.id) }
      end
    end

    class << self
      attr_writer :store, :dispatcher

      def policies = @policies ||= Policies::Registry.new
      def evaluators = @evaluators ||= Evaluators::Registry.new
      def generators = @generators ||= Generators::Registry.new
      def dispatcher
        return @dispatcher if @dispatcher
        return unless defined?(Agentkit::ExplorationWorldJob)

        lambda do |world_id, scope|
          Agentkit::ExplorationWorldJob.perform_later(world_id, scope)
        end
      end

      def store
        return @store if @store
        return @store = Stores::Memory.new if Agentkit.config.exploration.store.to_sym == :memory
        return Stores::ActiveRecord.new if active_record_available?

        @store = Stores::Memory.new
      end

      def reset!
        @store = nil
        @policies = Policies::Registry.new
        @evaluators = Evaluators::Registry.new
        @generators = Generators::Registry.new
        @dispatcher = nil
        Quota.reset! if defined?(Quota)
        Governance.reset! if defined?(Governance)
        self
      end

      def run(objective:, policy: :portfolio, version: "1", generator:, evaluator:, evaluator_id: nil,
              evaluator_version: nil, generator_id: nil, generator_version: nil,
              max_rounds: nil, max_parallelism: nil, max_nodes: nil, beta: nil,
              baseline_score: 0.0, metadata: {}, scope: nil)
        raise ConfigurationError, "adaptive exploration is disabled" unless Agentkit.config.exploration.enabled

        settings = Agentkit.config.exploration
        resolved_beta = beta.nil? ? settings.default_beta.to_f : bounded_beta(beta)
        spec = resolve_policy(policy, version: version, beta: resolved_beta)
        generator_spec = resolve_generator(generator, generator_id: generator_id,
                                           version: generator_version)
        evaluator_spec = resolve_evaluator(evaluator, evaluator_id: evaluator_id,
                                                      version: evaluator_version)
        resolved_scope = Scope.resolve(scope)
        world_id = SecureRandom.uuid
        Quota.reserve!(resource: :worlds, amount: 1, reservation_key: "world:#{world_id}",
                       scope: resolved_scope)
        OnlineRunner.new(
          policy_spec: spec, evaluator_spec: evaluator_spec,
          generator_spec: generator_spec, store: store, scope: resolved_scope,
          max_rounds: bounded_positive(max_rounds, settings.max_rounds),
          max_parallelism: bounded_positive(max_parallelism, settings.max_parallelism),
          max_nodes: bounded_positive(max_nodes, settings.max_nodes),
          beta: resolved_beta, baseline_score: baseline_score, world_id: world_id
        ).run(objective: objective, metadata: metadata)
      end

      # Persist first, dispatch second. A duplicate Active Job delivery is safe:
      # the world lease admits only one worker and terminal worlds are no-ops.
      # Only versioned registry entries are accepted because Procs cannot be
      # reconstructed reliably in another process.
      def enqueue(objective:, generator:, generator_version:, evaluator:, evaluator_version:,
                  policy: :portfolio, version: "1", max_rounds: nil,
                  max_parallelism: nil, max_nodes: nil, beta: nil,
                  baseline_score: 0.0, metadata: {}, scope: nil)
        raise ConfigurationError, "adaptive exploration is disabled" unless Agentkit.config.exploration.enabled
        unless Agentkit.config.exploration.execution.to_s == "distributed"
          raise ConfigurationError, "distributed exploration is disabled"
        end
        unless store.is_a?(Stores::ActiveRecord) && Quota.store.is_a?(Quota::ActiveRecordStore)
          raise ConfigurationError,
                "distributed exploration requires migrated ActiveRecord world and quota stores"
        end

        settings = Agentkit.config.exploration
        resolved_scope = Scope.resolve(scope)
        resolved_beta = beta.nil? ? settings.default_beta.to_f : bounded_beta(beta)
        policy_spec = resolve_policy(policy, version: version, beta: resolved_beta)
        generator_spec = generators.fetch(generator, version: generator_version)
        evaluator_spec = evaluators.fetch(evaluator, version: evaluator_version)
        world_id = SecureRandom.uuid
        Quota.reserve!(resource: :worlds, amount: 1, reservation_key: "world:#{world_id}",
                       scope: resolved_scope)
        now = Time.now.utc
        world = World.new(
          id: world_id, tenant_key: resolved_scope.tenant_key || "__global__",
          account_id: resolved_scope.account_id,
          objective_digest: digest_for(objective.to_s),
          policy_name: policy_spec.name, policy_version: policy_spec.version,
          policy_digest: policy_spec.digest,
          generator_digest: generator_spec.digest, generator_manifest: generator_spec.to_h,
          evaluator_digest: evaluator_spec.digest, evaluator_manifest: evaluator_spec.to_h,
          bounds: { max_rounds: bounded_positive(max_rounds, settings.max_rounds),
                    max_parallelism: bounded_positive(max_parallelism, settings.max_parallelism),
                    max_nodes: bounded_positive(max_nodes, settings.max_nodes),
                    beta: resolved_beta, baseline_score: normalized_baseline(evaluator_spec, baseline_score),
                    evaluator_baseline_score: finite_number(baseline_score, "baseline score") },
          nodes: [Node.new(id: ROOT_ID, parent_id: nil, sequence: 0)], rounds: 0,
          status: "queued", stop_reason: nil, created_at: now, completed_at: nil,
          metadata: bounded_payload(metadata)
        )
        store.save(world)
        dispatch(world.id, resolved_scope)
        Telemetry.emit("exploration.world.enqueued",
                       dims: { policy: policy_spec.name }, measures: { count: 1 })
        world
      end

      def work(world:, scope: nil)
        resolved_scope = Scope.resolve(scope)
        saved = find_world(world, scope: resolved_scope, include_incomplete: true)
        return saved if %w[completed failed].include?(saved.status)

        generator_name = saved.generator_manifest.fetch("name")
        generator_version = saved.generator_manifest.fetch("version")
        evaluator_name = saved.evaluator_manifest.fetch("name")
        evaluator_version = saved.evaluator_manifest.fetch("version")
        resume(world: saved, policy: saved.policy_name, version: saved.policy_version,
               generator: generator_name, generator_version: generator_version,
               evaluator: evaluator_name, evaluator_version: evaluator_version,
               scope: resolved_scope)
      rescue KeyError
        raise ConfigurationError, "distributed world has incomplete component manifests"
      end

      def resume(world:, generator:, evaluator:, evaluator_id: nil, evaluator_version: nil,
                 generator_id: nil, generator_version: nil,
                 policy: nil, version: nil, scope: nil)
        raise ConfigurationError, "adaptive exploration is disabled" unless Agentkit.config.exploration.enabled

        resolved_scope = Scope.resolve(scope)
        saved = find_world(world, scope: resolved_scope, include_incomplete: true)
        unless %w[queued running].include?(saved.status)
          raise ConfigurationError, "only a queued or running exploration world can resume"
        end

        beta = saved.bounds.fetch("beta").to_f
        policy_spec = resolve_policy(policy || saved.policy_name,
                                     version: version || saved.policy_version, beta: beta)
        unless policy_spec.digest == saved.policy_digest
          raise ConfigurationError, "resumed exploration policy does not match the checkpoint"
        end
        evaluator_spec = resolve_evaluator(evaluator, evaluator_id: evaluator_id,
                                                      version: evaluator_version)
        unless evaluator_spec.digest == saved.evaluator_digest
          raise ConfigurationError, "resumed evaluator does not match the checkpoint manifest"
        end
        generator_spec = resolve_generator(generator, generator_id: generator_id,
                                           version: generator_version)
        if saved.generator_digest && generator_spec.digest != saved.generator_digest
          raise ConfigurationError, "resumed generator does not match the checkpoint manifest"
        end

        OnlineRunner.new(
          policy_spec: policy_spec, evaluator_spec: evaluator_spec,
          generator_spec: generator_spec, store: store, scope: resolved_scope,
          max_rounds: saved.bounds.fetch("max_rounds").to_i,
          max_parallelism: saved.bounds.fetch("max_parallelism").to_i,
          max_nodes: saved.bounds.fetch("max_nodes").to_i,
          beta: beta,
          baseline_score: saved.bounds.fetch("evaluator_baseline_score",
                                              saved.bounds.fetch("baseline_score", 0.0)),
          world: saved
        ).run
      end

      def attempts(world:, scope: nil)
        resolved_scope = Scope.resolve(scope)
        world_id = world.respond_to?(:id) ? world.id : world
        store.attempts(world_id, scope: resolved_scope)
      end

      def operations(scope: nil, limit: 50)
        resolved_scope = Scope.resolve(scope)
        maximum = [[Integer(limit), 1].max, 200].min
        data = if store.respond_to?(:operations)
                 store.operations(scope: resolved_scope, limit: maximum)
               else
                 memory_operations(resolved_scope, maximum)
               end
        world_counts = %w[queued running completed failed].to_h do |status|
          [status, data.fetch(:world_counts).fetch(status, 0)]
        end
        attempt_counts = %w[pending running completed failed execution_unknown].to_h do |status|
          [status, data.fetch(:attempt_counts).fetch(status, 0)]
        end
        OperationsSnapshot.new(
          generated_at: Time.now.utc, world_counts: world_counts.freeze,
          attempt_counts: attempt_counts.freeze,
          quotas: Quota.snapshots(scope: resolved_scope).transform_values(&:to_h).freeze,
          recent_worlds: data.fetch(:recent_worlds).freeze
        ).freeze
      rescue ArgumentError, TypeError
        raise ConfigurationError, "exploration dashboard limit must be an integer"
      end

      def redispatch(world:, scope: nil)
        resolved_scope = Scope.resolve(scope)
        saved = find_world(world, scope: resolved_scope, include_incomplete: true)
        unless %w[queued running].include?(saved.status)
          raise ConfigurationError, "only a queued or running exploration world can be redispatched"
        end

        dispatch(saved.id, resolved_scope)
        saved
      end

      # Explicit operator reconciliation is required before an ambiguous
      # attempt may be retried or projected into the discovery tree.
      def reconcile_attempt!(attempt_id, status:, outcome: {}, scope: nil)
        resolved_scope = Scope.resolve(scope)
        target = status.to_s
        unless %w[pending completed failed].include?(target)
          raise ConfigurationError, "reconciled attempt status must be pending, completed or failed"
        end
        attrs = {}
        if target == "completed"
          normalized = normalize_reconciled_outcome(outcome)
          attrs = {
            node_id: SecureRandom.uuid, score: normalized.fetch(:score),
            outcome_status: normalized.fetch(:status, "ok"),
            artifact_digest: normalized_artifact_digest(normalized[:artifact_digest], attempt_id),
            failure_class: normalized[:failure_class],
            diagnostics: bounded_payload(normalized[:diagnostics] || {}),
            metadata: bounded_payload(normalized[:metadata] || {}), completed_at: Time.now.utc
          }
        elsif target == "failed"
          attrs = { node_id: SecureRandom.uuid, score: nil, outcome_status: "error",
                    failure_class: outcome[:failure_class] || outcome["failure_class"] || "reconciled_failure",
                    artifact_digest: digest_for(reconciled: attempt_id, status: target),
                    diagnostics: bounded_payload(outcome), metadata: {}, completed_at: Time.now.utc }
        else
          attrs = { started_at: nil, completed_at: nil }
        end
        result = store.transition_attempt(attempt_id, from: "execution_unknown", to: target,
                                          attrs: attrs, scope: resolved_scope)
        current_context = Context.current
        audit_context = if current_context&.tenant_key.to_s == result.tenant_key.to_s
                          current_context
                        else
                          Context.new(account: result.account_id, tenant_key: result.tenant_key,
                                      principal: resolved_scope.principal)
                        end
        Audit.record(event_type: "exploration.attempt.reconciled", status: target,
                     payload: { attempt_id: result.id, world_id: result.world_id,
                                artifact_digest: result.artifact_digest,
                                failure_class: result.failure_class },
                     context: audit_context)
        Telemetry.emit("exploration.attempt.reconciled", dims: { status: target }, measures: { count: 1 })
        result
      end

      def replay(world:, policy: :portfolio, version: "1", max_rounds: nil,
                 max_parallelism: nil, beta: nil, cost_penalty: nil, parallelism_bonus: nil)
        world = find_world(world)
        raise ConfigurationError, "only completed exploration worlds can be replayed" unless world.status == "completed"
        settings = Agentkit.config.exploration
        resolved_beta = beta.nil? ? world.bounds.fetch("beta", settings.default_beta).to_f : bounded_beta(beta)
        spec = resolve_policy(policy, version: version, beta: resolved_beta)
        world_width = world.bounds.fetch("max_parallelism", settings.max_parallelism).to_i
        requested_width = bounded_positive(max_parallelism, settings.max_parallelism)
        result = Replayer.new(
          world: world, policy_spec: spec,
          max_rounds: bounded_positive(max_rounds, settings.replay_max_rounds),
          max_parallelism: [requested_width, world_width].min,
          beta: resolved_beta,
          cost_penalty: finite_non_negative(cost_penalty.nil? ? settings.cost_penalty : cost_penalty),
          parallelism_bonus: finite_non_negative(parallelism_bonus.nil? ? settings.parallelism_bonus : parallelism_bonus)
        ).run
        Telemetry.emit("exploration.replay.completed",
                       dims: { policy: spec.name, policy_version: spec.version,
                               stop_reason: result.stop_reason },
                       measures: { score: result.score, quality: result.best_score,
                                   attempts: result.attempts, rounds: result.rounds,
                                   parallelism: result.parallelism,
                                   decision_coverage: result.decision_coverage,
                                   unsupported_actions: result.unsupported_actions })
        result
      end

      def evaluate(policy:, worlds: nil, version: "1", **options)
        selected_worlds = Array(worlds || store.all(scope: Scope.resolve))
        raise ConfigurationError, "replay evaluation needs at least one world" if selected_worlds.empty?
        if selected_worlds.map(&:evaluator_digest).uniq.size > 1
          raise ConfigurationError, "replay evaluation requires one fixed evaluator digest"
        end

        beta = options.key?(:beta) ? options[:beta] : nil
        spec = resolve_policy(policy, version: version,
                              beta: beta.nil? ? Agentkit.config.exploration.default_beta : bounded_beta(beta))
        replays = selected_worlds.map { |world| replay(world: world, policy: spec, version: spec.version, **options) }
        Evaluation.new(
          policy_name: spec.name, policy_version: spec.version, policy_digest: spec.digest,
          history_digest: digest_for(selected_worlds.map(&:digest).sort), world_count: replays.size,
          mean_score: mean(replays.map(&:score)), mean_quality: mean(replays.map(&:best_score)),
          mean_attempts: mean(replays.map(&:attempts)), mean_rounds: mean(replays.map(&:rounds)),
          mean_parallelism: mean(replays.map(&:parallelism)),
          mean_coverage: mean(replays.map(&:decision_coverage)),
          min_coverage: replays.map(&:decision_coverage).min,
          unsupported_actions: replays.sum(&:unsupported_actions), replays: replays
        )
      end

      def split_holdout(worlds:, holdout_worlds: nil)
        training = Array(worlds).map { |world| find_world(world) }
        raise ConfigurationError, "holdout split needs at least one world" if training.empty?

        if holdout_worlds.nil?
          fraction = Agentkit.config.exploration.holdout_fraction.to_f
          seed = Agentkit.config.exploration.holdout_seed.to_s
          training, holdout = training.partition do |world|
            stable_holdout_bucket(world, seed) >= fraction
          end
          strategy = "stable_hash_v1"
        else
          holdout = Array(holdout_worlds).map { |world| find_world(world) }
          strategy = "explicit"
        end
        validate_holdout_sets!(training, holdout)
        training_digest = digest_for(training.map(&:digest).sort)
        holdout_digest = digest_for(holdout.map(&:digest).sort)
        HoldoutSplit.new(
          strategy: strategy, training_worlds: training.freeze, holdout_worlds: holdout.freeze,
          training_digest: training_digest, holdout_digest: holdout_digest,
          assignment_digest: digest_for(strategy: strategy,
                                        seed_digest: strategy == "stable_hash_v1" ? digest_for(
                                          Agentkit.config.exploration.holdout_seed.to_s
                                        ) : nil,
                                        training: training_digest, holdout: holdout_digest)
        ).freeze
      end

      def pareto_frontier(evaluations:, epsilon: nil)
        resolved_epsilon = finite_non_negative(
          epsilon.nil? ? Agentkit.config.exploration.pareto_epsilon : epsilon,
          label: "Pareto epsilon"
        )
        Pareto.frontier(evaluations, epsilon: resolved_epsilon)
      end

      def compare(incumbent:, candidate:, worlds:, incumbent_version: "1", candidate_version: "1", **options)
        selected_worlds = Array(worlds)
        incumbent_evaluation = evaluate(policy: incumbent, version: incumbent_version,
                                        worlds: selected_worlds, **options)
        candidate_evaluation = evaluate(policy: candidate, version: candidate_version,
                                        worlds: selected_worlds, **options)
        compare_evaluations(incumbent_evaluation, candidate_evaluation)
      end

      # Returns an N3 recommendation only. Applying it remains a separate,
      # reviewed Factory intervention; this method cannot mutate the registry.
      def recommend(incumbent:, candidates:, worlds: nil, holdout_worlds: nil)
        list = [incumbent, *Array(candidates)].uniq
        settings = Agentkit.config.exploration
        maximum = settings.max_policies.to_i
        raise ConfigurationError, "too many exploration policies (max #{maximum})" if list.size > maximum

        pool = Array(worlds || store.all(scope: Scope.resolve))
        split = split_holdout(worlds: pool, holdout_worlds: holdout_worlds)
        all_worlds = split.training_worlds + split.holdout_worlds
        minimum = settings.min_replay_worlds.to_i
        minimum_training = [minimum, settings.min_training_worlds.to_i].max
        minimum_holdout = settings.min_holdout_worlds.to_i
        insufficient_reason = if all_worlds.size < minimum
                                "insufficient_replay_worlds"
                              elsif split.training_worlds.size < minimum_training
                                "insufficient_training_worlds"
                              elsif split.holdout_worlds.size < minimum_holdout
                                "insufficient_holdout_worlds"
                              end
        if insufficient_reason
          evaluations = if split.training_worlds.empty?
                          []
                        else
                          list.map { |policy| evaluate(policy: policy, worlds: split.training_worlds) }
                        end
          frontier = pareto_frontier(evaluations: evaluations)
          incumbent_name = evaluations.first&.policy_name ||
                           resolve_policy(incumbent, version: "1", beta: settings.default_beta).name
          return Recommendation.new(
            status: "retain", level: "n3", incumbent: incumbent_name,
            selected: incumbent_name, evaluations: evaluations,
            holdout_evaluations: [], pareto_frontier: pareto_descriptors(frontier),
            holdout: split.to_h, comparison: nil, requires_review: true,
            auto_promoted: false, reason: insufficient_reason
          )
        end

        evaluations = list.map { |policy| evaluate(policy: policy, worlds: split.training_worlds) }
        current = evaluations.first
        frontier = pareto_frontier(evaluations: evaluations)
        coverage_floor = settings.min_replay_coverage.to_f
        eligible = frontier.select { |evaluation| evaluation.mean_coverage >= coverage_floor }
        best = eligible.max_by do |evaluation|
          [evaluation.mean_score, evaluation.mean_quality, -evaluation.mean_attempts,
           evaluation.policy_name]
        end || current
        coverage_sufficient = current.mean_coverage >= coverage_floor && best.mean_coverage >= coverage_floor
        training_improved = best != current && best.mean_score > current.mean_score
        selected_index = evaluations.index(best)
        selected_policy = list.fetch(selected_index)
        holdout_evaluations = []
        comparison = nil
        holdout_pareto = false

        if coverage_sufficient && training_improved
          holdout_evaluations = [incumbent, selected_policy].map do |policy|
            evaluate(policy: policy, worlds: split.holdout_worlds)
          end
          holdout_pareto = pareto_frontier(evaluations: holdout_evaluations).include?(holdout_evaluations.last)
          comparison = compare_evaluations(holdout_evaluations.first, holdout_evaluations.last)
        end

        holdout_coverage = holdout_evaluations.empty? ||
                           holdout_evaluations.all? { |evaluation| evaluation.mean_coverage >= coverage_floor }
        approved = coverage_sufficient && training_improved && holdout_coverage &&
                   holdout_pareto && comparison&.significant
        reason = if !coverage_sufficient
                   "insufficient_replay_coverage"
                 elsif !training_improved
                   "no_pareto_training_improvement"
                 elsif !holdout_coverage
                   "insufficient_holdout_coverage"
                 elsif !holdout_pareto
                   "holdout_pareto_regression"
                 elsif comparison.significant
                   "statistically_significant_holdout_improvement"
                 else
                   "statistically_inconclusive"
                 end
        recommendation = Recommendation.new(
          status: approved ? "recommend_review" : "retain",
          level: "n3", incumbent: current.policy_name,
          selected: approved ? best.policy_name : current.policy_name,
          evaluations: evaluations, holdout_evaluations: holdout_evaluations,
          pareto_frontier: pareto_descriptors(frontier), holdout: split.to_h,
          comparison: comparison, requires_review: true, auto_promoted: false,
          reason: reason
        )
        Telemetry.emit("exploration.recommendation.evaluated",
                       dims: { status: recommendation.status, reason: recommendation.reason },
                       measures: { training_worlds: split.training_worlds.size,
                                   holdout_worlds: split.holdout_worlds.size,
                                   pareto_policies: frontier.size,
                                   mean_difference: comparison&.mean_difference.to_f })
        recommendation
      end

      # Offline beta sweep: each point is a fresh prefix-only replay. Beta is
      # never changed inside an episode, avoiding an oracle-like feedback loop.
      def sweep(policy: :portfolio, worlds: nil, betas: [0.2, 0.4, 0.6, 0.8])
        grid = Array(betas).map { |value| bounded_beta(value) }.uniq.sort
        maximum = Agentkit.config.exploration.max_policies.to_i
        raise ConfigurationError, "beta sweep has too many points (max #{maximum})" if grid.size > maximum

        grid.to_h do |value|
          [value, evaluate(policy: policy, worlds: worlds, beta: value)]
        end
      end

      # Conservative cross-cycle planning matching the paper's separation:
      # live evidence establishes a plateau, replay establishes the trade-off,
      # and the selected beta remains fixed throughout the next live episode.
      def plan_beta(current_beta:, worlds:, sweep:)
        current = bounded_beta(current_beta)
        history = Array(worlds).sort_by(&:created_at).last(3)
        evidence = sweep.to_h.transform_keys { |value| bounded_beta(value) }
        return BetaPlan.new(current_beta: current, recommended_beta: current,
                            reason: "insufficient_live_history", requires_review: true,
                            evidence: { live_worlds: history.size }) if history.size < 2 || evidence.empty?

        live_scores = history.map { |world| world.best_score || world.bounds.fetch("baseline_score", 0.0).to_f }
        scale = [live_scores.map(&:abs).max.to_f, 1.0].max
        improving = (live_scores.last - live_scores.first) > (scale * 0.01)
        current_eval = evidence.min_by { |beta_value, _| (beta_value - current).abs }&.last
        best_beta, best_eval = evidence.max_by { |beta_value, evaluation| [evaluation.mean_score, -((beta_value - current).abs)] }
        recommended = current
        reason = improving ? "live_improving_keep_beta" : "plateau_no_efficient_replay_gain"

        if !improving && best_eval && current_eval && best_eval.mean_score > current_eval.mean_score
          quality_gain = best_eval.mean_quality > current_eval.mean_quality
          reasonable_work = best_eval.mean_attempts <= [current_eval.mean_attempts * 1.25, current_eval.mean_attempts + 1].max
          if best_beta > current && quality_gain && reasonable_work
            recommended = [current + 0.2, best_beta, 1.0].min
            reason = "plateau_higher_beta_improves_attainment"
          elsif best_beta < current && best_eval.mean_quality >= current_eval.mean_quality
            recommended = [current - 0.2, best_beta, 0.0].max
            reason = "lower_beta_matches_attainment_with_better_reward"
          end
        end
        BetaPlan.new(current_beta: current, recommended_beta: recommended.round(4),
                     reason: reason, requires_review: true,
                     evidence: { live_scores: live_scores, replay_points: evidence.keys.sort })
      end

      def digest_for(value)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
      end

      private

      def resolve_policy(policy, version:, beta:)
        if policy.is_a?(PolicySpec)
          policy
        elsif policy.respond_to?(:select)
          PolicySpec.new(name: policy.class.name.to_s, version: version.to_s,
                         digest: digest_for(name: policy.class.name.to_s, version: version.to_s),
                         policy: policy)
        elsif policy.to_sym == :portfolio
          object = Policies::Portfolio.new(beta: beta)
          PolicySpec.new(name: "portfolio", version: version.to_s,
                         digest: digest_for(name: "portfolio", version: version.to_s, beta: beta),
                         policy: object)
        else
          policies.fetch(policy, version: version)
        end
      end

      def resolve_generator(generator, generator_id:, version:)
        return generator if generator.is_a?(GeneratorManifest)

        if generator.respond_to?(:call)
          registry = generator_id ? generators : Generators::Registry.new
          registry.register(generator_id || "callable", version: version || "legacy",
                            generator: generator)
        else
          raise ConfigurationError, "exploration generator_version is required" if version.to_s.empty?

          generators.fetch(generator, version: version)
        end
      end

      def resolve_evaluator(evaluator, evaluator_id:, version:)
        return evaluator if evaluator.is_a?(EvaluatorManifest)

        if evaluator.respond_to?(:call)
          raise ConfigurationError, "exploration evaluator_id is required" if evaluator_id.to_s.empty?

          evaluators.register(evaluator_id, version: version || "legacy", evaluator: evaluator)
        else
          raise ConfigurationError, "exploration evaluator_version is required" if version.to_s.empty?

          evaluators.fetch(evaluator, version: version)
        end
      end

      def dispatch(world_id, scope)
        worker = dispatcher
        unless worker.respond_to?(:call)
          raise ConfigurationError,
                "distributed exploration dispatcher is unavailable; boot the Rails engine or configure one"
        end

        worker.call(world_id.to_s, scope.to_h)
      end

      def finite_number(value, label)
        number = Float(value)
        raise ConfigurationError, "exploration #{label} must be finite" unless number.finite?

        number
      rescue ArgumentError, TypeError
        raise ConfigurationError, "exploration #{label} must be numeric"
      end

      def normalized_baseline(evaluator_spec, value)
        baseline = finite_number(value, "baseline score")
        evaluator_spec.normalization.to_sym == :relative_to_baseline ? 0.0 : baseline
      end

      def memory_operations(scope, limit)
        worlds = store.all(scope: scope, include_incomplete: true)
        attempts = worlds.flat_map { |world| store.attempts(world.id, scope: scope) }
        recent = worlds.sort_by(&:created_at).last(limit).reverse.map do |world|
          { id: world.id, status: world.status, policy_name: world.policy_name,
            policy_version: world.policy_version, rounds: world.rounds,
            node_count: world.node_count, best_score: world.best_score,
            stop_reason: world.stop_reason.to_s.empty? ? nil : world.stop_reason,
            evaluator_digest: world.evaluator_digest,
            created_at: world.created_at, completed_at: world.completed_at }
        end
        { world_counts: worlds.group_by(&:status).transform_values(&:size),
          attempt_counts: attempts.group_by(&:status).transform_values(&:size),
          recent_worlds: recent }
      end

      def find_world(value, scope: nil, include_incomplete: false)
        if value.is_a?(World)
          resolved_scope = scope || Scope.resolve
          raise ConfigurationError, "exploration world belongs to another scope" unless resolved_scope.match?(value)

          return value
        end

        store.find(value, scope: scope || Scope.resolve, include_incomplete: include_incomplete) ||
          raise(ConfigurationError, "exploration world not found")
      end

      def validate_holdout_sets!(training, holdout)
        combined = training + holdout
        ids = combined.map(&:id)
        raise ConfigurationError, "training and holdout worlds must be disjoint" unless ids.uniq.size == ids.size
        unless combined.all? { |world| world.status == "completed" }
          raise ConfigurationError, "holdout evaluation requires completed worlds"
        end
        if combined.map(&:evaluator_digest).uniq.size > 1
          raise ConfigurationError, "training and holdout require one fixed evaluator digest"
        end
      end

      def stable_holdout_bucket(world, seed)
        hex = Digest::SHA256.hexdigest("#{seed}:#{world.digest}")[0, 16]
        hex.to_i(16).to_f / (16**16)
      end

      def pareto_descriptors(evaluations)
        evaluations.map do |evaluation|
          { policy_name: evaluation.policy_name, policy_version: evaluation.policy_version,
            policy_digest: evaluation.policy_digest }
        end
      end

      def compare_evaluations(incumbent, candidate)
        unless incumbent.history_digest == candidate.history_digest
          raise ConfigurationError, "statistical comparison requires paired replay history"
        end
        incumbent_scores = incumbent.replays.to_h { |replay| [replay.world_id, replay.score.to_f] }
        candidate_scores = candidate.replays.to_h { |replay| [replay.world_id, replay.score.to_f] }
        unless incumbent_scores.keys.sort == candidate_scores.keys.sort
          raise ConfigurationError, "statistical comparison requires the same replay worlds"
        end

        differences = incumbent_scores.keys.sort.map do |world_id|
          candidate_scores.fetch(world_id) - incumbent_scores.fetch(world_id)
        end
        settings = Agentkit.config.exploration
        samples = Integer(settings.bootstrap_samples)
        confidence = Float(settings.confidence_level)
        raise ConfigurationError, "bootstrap samples must be at least 100" if samples < 100
        unless confidence.finite? && confidence.positive? && confidence < 1.0
          raise ConfigurationError, "confidence level must be strictly between 0 and 1"
        end
        minimum_effect = finite_non_negative(settings.min_score_improvement,
                                             label: "minimum score improvement")
        seed_digest = digest_for(
          history: incumbent.history_digest, incumbent: incumbent.policy_digest,
          candidate: candidate.policy_digest, samples: samples, confidence: confidence,
          minimum_effect: minimum_effect
        )
        random = Random.new(seed_digest.delete_prefix("sha256:")[0, 16].to_i(16))
        bootstrapped = Array.new(samples) do
          mean(Array.new(differences.size) { differences.fetch(random.rand(differences.size)) })
        end.sort
        alpha = (1.0 - confidence) / 2.0
        lower = percentile(bootstrapped, alpha)
        upper = percentile(bootstrapped, 1.0 - alpha)
        mean_difference = mean(differences)
        standard_error = if differences.size > 1
                           variance = differences.sum { |value| (value - mean_difference)**2 } /
                                      (differences.size - 1).to_f
                           Math.sqrt(variance / differences.size)
                         else
                           0.0
                         end
        StatisticalComparison.new(
          metric: "replay_score", sample_size: differences.size,
          mean_difference: mean_difference, median_difference: percentile(differences.sort, 0.5),
          standard_error: standard_error, ci_lower: lower, ci_upper: upper,
          confidence_level: confidence,
          bootstrap_superiority_rate: bootstrapped.count { |value| value > minimum_effect }.to_f / samples,
          minimum_effect: minimum_effect,
          significant: differences.size >= settings.min_holdout_worlds.to_i && lower > minimum_effect,
          method: "paired_percentile_bootstrap", seed_digest: seed_digest
        ).freeze
      rescue ArgumentError, TypeError
        raise ConfigurationError, "statistical evaluation settings are invalid"
      end

      def percentile(sorted_values, probability)
        return sorted_values.first.to_f if sorted_values.size == 1

        rank = probability * (sorted_values.size - 1)
        lower = rank.floor
        upper = rank.ceil
        return sorted_values.fetch(lower).to_f if lower == upper

        left = sorted_values.fetch(lower).to_f
        left + ((sorted_values.fetch(upper).to_f - left) * (rank - lower))
      end

      def normalize_reconciled_outcome(value)
        hash = value.to_h.transform_keys(&:to_sym)
        score = Float(hash.fetch(:score))
        raise ConfigurationError, "reconciled exploration score must be finite" unless score.finite?

        hash.merge(score: score)
      rescue KeyError, ArgumentError, TypeError
        raise ConfigurationError, "reconciled exploration outcome needs a finite score"
      end

      def normalized_artifact_digest(value, attempt_id)
        return digest_for(reconciled: attempt_id) if value.nil?

        string = value.to_s
        string.start_with?("sha256:") ? string : digest_for(string)
      end

      def bounded_payload(value)
        sanitized = Audit.sanitize_payload(value)
        bytes = JSON.generate(sanitized).bytesize
        return sanitized if bytes <= Agentkit.config.exploration.max_diagnostics_bytes.to_i

        { "truncated" => true, "digest" => digest_for(sanitized), "bytes" => bytes }
      end

      def bounded_positive(requested, configured)
        ceiling = Integer(configured)
        return ceiling if requested.nil?

        value = Integer(requested)
        raise ConfigurationError, "exploration limit must be positive" unless value.positive?

        [value, ceiling].min
      rescue ArgumentError, TypeError
        raise ConfigurationError, "exploration limit must be an integer"
      end

      def bounded_beta(value)
        number = Float(value)
        raise ConfigurationError, "exploration beta must be between 0 and 1" unless number.finite? && number.between?(0.0, 1.0)

        number
      rescue ArgumentError, TypeError
        raise ConfigurationError, "exploration beta must be between 0 and 1"
      end

      def finite_non_negative(value, label: "replay coefficient")
        number = Float(value)
        raise ConfigurationError, "#{label} must be finite and non-negative" unless number.finite? && number >= 0

        number
      rescue ArgumentError, TypeError
        raise ConfigurationError, "#{label} must be finite and non-negative"
      end

      def mean(values) = values.sum.to_f / values.size

      def canonical(value)
        case value
        when Hash
          value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, canonical(value[key])] }
        when Array then value.map { |item| canonical(item) }
        when Time then value.utc.iso8601(6)
        else
          if value.respond_to?(:to_h) && !value.is_a?(Struct)
            canonical(value.to_h)
          elsif value.is_a?(Struct)
            canonical(value.to_h)
          else
            value
          end
        end
      end

      def active_record_available?
        Agentkit.config.exploration.store.to_sym == :active_record &&
          defined?(Agentkit::ExplorationWorldRecord) &&
          Agentkit::ExplorationWorldRecord.table_exists?
      rescue StandardError
        false
      end
    end

  end
end
