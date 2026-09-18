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
    SCHEMA_VERSION = 1
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
                  :rounds, :status, :stop_reason, :created_at, :completed_at, :metadata

      def initialize(id:, objective_digest:, policy_name:, policy_version:, policy_digest:,
                     evaluator_digest:, bounds:, nodes:, rounds:, status:, stop_reason:,
                     tenant_key: "__global__", account_id: nil, created_at: Time.now.utc,
                     completed_at: Time.now.utc, metadata: {})
        @id = id.to_s
        @tenant_key = tenant_key.to_s
        @account_id = account_id
        @objective_digest = objective_digest.to_s
        @policy_name = policy_name.to_s
        @policy_version = policy_version.to_s
        @policy_digest = policy_digest.to_s
        @evaluator_digest = evaluator_digest.to_s
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
        { schema_version: SCHEMA_VERSION, id: id, tenant_key: tenant_key, account_id: account_id,
          objective_digest: objective_digest, policy_name: policy_name,
          policy_version: policy_version, policy_digest: policy_digest,
          evaluator_digest: evaluator_digest, bounds: bounds, nodes: nodes.map(&:to_h),
          rounds: rounds, status: status, stop_reason: stop_reason,
          created_at: created_at.utc.iso8601(6), completed_at: completed_at.utc.iso8601(6),
          metadata: metadata }
      end

      def self.from_h(value)
        attrs = value.to_h.transform_keys(&:to_sym)
        attrs[:id] ||= attrs.delete(:world_id)
        attrs[:nodes] = Array(attrs[:nodes]).map do |node|
          node.is_a?(Node) ? node : Node.new(**node.transform_keys(&:to_sym))
        end
        attrs.delete(:schema_version)
        new(**attrs)
      end

      private

      def validate!
        required = [id, objective_digest, policy_name, policy_version, policy_digest, evaluator_digest]
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
        raise ConfigurationError, "exploration world status is invalid" unless %w[completed failed].include?(status)
        raise ConfigurationError, "exploration world stop reason is required" if stop_reason.empty?
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
      attr_reader :nodes, :legal_actions, :round, :max_parallelism, :beta, :baseline_score

      def initialize(nodes:, legal_actions:, round:, max_parallelism:, beta:, baseline_score: 0.0)
        @nodes = Array(nodes).dup.freeze
        @legal_actions = Array(legal_actions).map(&:to_s).freeze
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
                              :stop_reason, keyword_init: true) do
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    Evaluation = Struct.new(:policy_name, :policy_version, :policy_digest, :history_digest,
                            :world_count, :mean_score, :mean_quality, :mean_attempts,
                            :mean_rounds, :mean_parallelism, :replays, keyword_init: true) do
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    Recommendation = Struct.new(:status, :level, :incumbent, :selected, :evaluations,
                                :requires_review, :auto_promoted, :reason, keyword_init: true) do
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    BetaPlan = Struct.new(:current_beta, :recommended_beta, :reason, :requires_review,
                          :evidence, keyword_init: true) do
      def changed? = current_beta != recommended_beta
      def to_h = members.to_h { |member| [member, public_send(member)] }
    end

    module Stores
      class Memory
        def initialize = @worlds = []

        def save(world)
          @worlds.reject! { |existing| existing.id == world.id && existing.tenant_key == world.tenant_key }
          @worlds << world
          world
        end

        def all(scope: Scope.resolve)
          @worlds.select { |world| scope.match?(world) }
        end

        def find(id, scope: Scope.resolve)
          all(scope: scope).find { |world| world.id == id.to_s }
        end

        def clear = @worlds.clear
      end

      class ActiveRecord
        def save(world)
          row = Agentkit::ExplorationWorldRecord.find_or_initialize_by(world_id: world.id,
                                                                        tenant_key: world.tenant_key)
          row.assign_attributes(
            account_id: world.account_id, objective_digest: world.objective_digest,
            policy_name: world.policy_name, policy_version: world.policy_version,
            policy_digest: world.policy_digest, evaluator_digest: world.evaluator_digest,
            bounds: world.bounds, tree: world.to_h, rounds: world.rounds,
            node_count: world.node_count, best_score: world.best_score,
            status: world.status, stop_reason: world.stop_reason,
            completed_at: world.completed_at, metadata: world.metadata
          )
          row.save!
          world
        end

        def all(scope: Scope.resolve)
          relation = Agentkit::ExplorationWorldRecord.all
          relation = relation.where(tenant_key: scope.tenant_key) if scope.tenant_key
          relation = relation.where(account_id: scope.account_id) if scope.account_id
          relation.order(:created_at).map { |row| World.from_h(row.tree) }
        end

        def find(id, scope: Scope.resolve)
          all(scope: scope).find { |world| world.id == id.to_s }
        end
      end
    end

    class OnlineRunner
      def initialize(policy_spec:, evaluator:, evaluator_id:, generator:, store:, scope:,
                     max_rounds:, max_parallelism:, max_nodes:, beta:, baseline_score:)
        raise ConfigurationError, "exploration generator must respond to #call" unless generator.respond_to?(:call)
        raise ConfigurationError, "exploration evaluator must respond to #call" unless evaluator.respond_to?(:call)
        raise ConfigurationError, "exploration evaluator_id is required" if evaluator_id.to_s.empty?

        @policy_spec = policy_spec
        @evaluator = evaluator
        @evaluator_digest = Exploration.digest_for(id: evaluator_id.to_s)
        @generator = generator
        @store = store
        @scope = scope
        @max_rounds = max_rounds
        @max_parallelism = max_parallelism
        @max_nodes = max_nodes
        @beta = beta
        @baseline_score = Float(baseline_score)
        raise ConfigurationError, "exploration baseline score must be finite" unless @baseline_score.finite?
      end

      def run(objective:, metadata: {})
        started = Time.now.utc
        nodes = [Node.new(id: ROOT_ID, parent_id: nil, sequence: 0)]
        rounds = 0
        stop_reason = "round_limit"

        while rounds < @max_rounds && (nodes.size - 1) < @max_nodes
          legal = online_legal_actions(nodes)
          view = View.new(nodes: nodes, legal_actions: legal, round: rounds,
                          max_parallelism: effective_width(nodes), beta: @beta,
                          baseline_score: @baseline_score)
          batch = Guard.batch!(@policy_spec.policy.select(view), view)
          if batch.empty?
            stop_reason = "policy_stop"
            break
          end

          execute_batch(batch, view).each do |parent_id, candidate, outcome|
            nodes << Node.new(id: SecureRandom.uuid, parent_id: parent_id,
                              sequence: nodes.size, score: outcome.fetch(:score),
                              status: outcome.fetch(:status, "ok"),
                              failure_class: outcome[:failure_class],
                              artifact_digest: Exploration.digest_for(candidate),
                              diagnostics: bounded(outcome[:diagnostics] || {}),
                              metadata: bounded(outcome[:metadata] || {}))
          end
          rounds += 1
        end
        stop_reason = "node_limit" if (nodes.size - 1) >= @max_nodes
        world = World.new(
          id: SecureRandom.uuid, tenant_key: @scope.tenant_key || "__global__",
          account_id: @scope.account_id, objective_digest: Exploration.digest_for(objective.to_s),
          policy_name: @policy_spec.name, policy_version: @policy_spec.version,
          policy_digest: @policy_spec.digest, evaluator_digest: @evaluator_digest,
          bounds: { max_rounds: @max_rounds, max_parallelism: @max_parallelism,
                    max_nodes: @max_nodes, beta: @beta, baseline_score: @baseline_score },
          nodes: nodes, rounds: rounds, status: "completed", stop_reason: stop_reason,
          created_at: started, completed_at: Time.now.utc, metadata: bounded(metadata)
        )
        @store.save(world)
        Telemetry.emit("exploration.online.completed",
                       dims: { policy: world.policy_name, policy_version: world.policy_version,
                               status: world.status, stop_reason: world.stop_reason },
                       measures: { rounds: world.rounds, nodes: world.node_count,
                                   best_score: world.best_score })
        world
      end

      private

      def online_legal_actions(nodes)
        parents = nodes.reject(&:root?).map(&:parent_id)
        [ROOT_ID] + nodes.reject(&:root?).reject { |node| parents.include?(node.id) }.map(&:id)
      end

      def effective_width(nodes)
        [@max_parallelism, @max_nodes - (nodes.size - 1)].min
      end

      def execute_batch(batch, view)
        jobs = batch.map do |parent_id|
          Thread.new do
            candidate = @generator.call(parent: parent_id == ROOT_ID ? nil : view.node(parent_id), view: view)
            [parent_id, candidate, normalize_outcome(@evaluator.call(candidate))]
          rescue ConfigurationError
            raise
          rescue StandardError => e
            Telemetry.emit("exploration.attempt.failed",
                           dims: { error_class: e.class.name }, measures: { count: 1 })
            [parent_id, { failed: true, error_class: e.class.name },
             { score: nil, status: "error", failure_class: e.class.name,
               diagnostics: { error_class: e.class.name } }]
          end
        end
        jobs.map(&:value)
      end

      def normalize_outcome(value)
        hash = value.to_h.transform_keys(&:to_sym)
        score = Float(hash.fetch(:score))
        raise ConfigurationError, "exploration evaluator score must be finite" unless score.finite?

        hash.merge(score: score)
      rescue KeyError, ArgumentError, TypeError
        raise ConfigurationError, "exploration evaluator must return a finite numeric score"
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
        while rounds < @max_rounds
          legal = replay_legal_actions(revealed)
          if legal.empty?
            stop_reason = "history_exhausted"
            break
          end
          view = View.new(nodes: revealed, legal_actions: legal, round: rounds,
                          max_parallelism: @max_parallelism, beta: @beta,
                          baseline_score: baseline_score)
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
        ReplayResult.new(world_id: @world.id, policy_name: @policy_spec.name,
                         policy_version: @policy_spec.version,
                         revealed_node_ids: revealed.map(&:id), best_score: quality,
                         attempts: attempts, rounds: rounds, parallelism: parallelism,
                         score: score, stop_reason: stop_reason)
      end

      private

      def baseline_score = Float(@world.bounds.fetch("baseline_score", 0.0))

      def replay_legal_actions(revealed)
        revealed_ids = revealed.map(&:id)
        parents = revealed.reject(&:root?).map(&:parent_id)
        candidates = [ROOT_ID] + revealed.reject(&:root?).reject { |node| parents.include?(node.id) }.map(&:id)
        candidates.select { |parent_id| @world.children_of(parent_id).any? { |child| !revealed_ids.include?(child.id) } }
      end

      def next_child(parent_id, revealed)
        ids = revealed.map(&:id)
        @world.children_of(parent_id).find { |child| !ids.include?(child.id) }
      end
    end

    class << self
      attr_writer :store

      def policies = @policies ||= Policies::Registry.new

      def store
        return @store if @store
        return @store = Stores::Memory.new if Agentkit.config.exploration.store.to_sym == :memory
        return Stores::ActiveRecord.new if active_record_available?

        @store = Stores::Memory.new
      end

      def reset!
        @store = nil
        @policies = Policies::Registry.new
        self
      end

      def run(objective:, policy: :portfolio, version: "1", generator:, evaluator:, evaluator_id:,
              max_rounds: nil, max_parallelism: nil, max_nodes: nil, beta: nil,
              baseline_score: 0.0, metadata: {}, scope: nil)
        raise ConfigurationError, "adaptive exploration is disabled" unless Agentkit.config.exploration.enabled

        settings = Agentkit.config.exploration
        resolved_beta = beta.nil? ? settings.default_beta.to_f : bounded_beta(beta)
        spec = resolve_policy(policy, version: version, beta: resolved_beta)
        OnlineRunner.new(
          policy_spec: spec, evaluator: evaluator, evaluator_id: evaluator_id,
          generator: generator, store: store, scope: Scope.resolve(scope),
          max_rounds: bounded_positive(max_rounds, settings.max_rounds),
          max_parallelism: bounded_positive(max_parallelism, settings.max_parallelism),
          max_nodes: bounded_positive(max_nodes, settings.max_nodes),
          beta: resolved_beta, baseline_score: baseline_score
        ).run(objective: objective, metadata: metadata)
      end

      def replay(world:, policy: :portfolio, version: "1", max_rounds: nil,
                 max_parallelism: nil, beta: nil, cost_penalty: nil, parallelism_bonus: nil)
        world = find_world(world)
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
                                   parallelism: result.parallelism })
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
          mean_parallelism: mean(replays.map(&:parallelism)), replays: replays
        )
      end

      # Returns an N3 recommendation only. Applying it remains a separate,
      # reviewed Factory intervention; this method cannot mutate the registry.
      def recommend(incumbent:, candidates:, worlds: nil)
        list = [incumbent, *Array(candidates)].uniq
        maximum = Agentkit.config.exploration.max_policies.to_i
        raise ConfigurationError, "too many exploration policies (max #{maximum})" if list.size > maximum

        selected_worlds = Array(worlds || store.all(scope: Scope.resolve))
        minimum = Agentkit.config.exploration.min_replay_worlds.to_i
        evaluations = list.map { |policy| evaluate(policy: policy, worlds: selected_worlds) }
        current = evaluations.first
        best = evaluations.max_by { |evaluation| [evaluation.mean_score, evaluation.policy_name] }
        enough = selected_worlds.size >= minimum
        improved = best.mean_score > current.mean_score
        Recommendation.new(
          status: enough && improved ? "recommend_review" : "retain",
          level: "n3", incumbent: current.policy_name,
          selected: enough && improved ? best.policy_name : current.policy_name,
          evaluations: evaluations, requires_review: true, auto_promoted: false,
          reason: enough ? (improved ? "higher_fixed_history_replay_score" : "no_replay_improvement") : "insufficient_replay_worlds"
        )
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

      def find_world(value)
        return value if value.is_a?(World)

        store.find(value, scope: Scope.resolve) || raise(ConfigurationError, "exploration world not found")
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

      def finite_non_negative(value)
        number = Float(value)
        raise ConfigurationError, "replay coefficient must be finite and non-negative" unless number.finite? && number >= 0

        number
      rescue ArgumentError, TypeError
        raise ConfigurationError, "replay coefficient must be finite and non-negative"
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
