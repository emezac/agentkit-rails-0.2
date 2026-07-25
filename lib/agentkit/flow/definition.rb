# frozen_string_literal: true

module Agentkit
  class Flow
    # Node types and the compiled graph.
    #
    # The graph is validated when the class is loaded, not when a run reaches a
    # bad node: a malformed flow fails on boot, never halfway through production.
    module Nodes
      class Base
        attr_reader :name, :opts

        def initialize(name, **opts)
          @name = name.to_sym
          @opts = opts
        end

        def kind      = self.class.name.split("::").last.sub("Node", "").downcase
        def guard     = opts[:if]
        def unless_guard = opts[:unless]
        def timeout   = opts[:timeout]
        def retry_spec = opts[:retry] || {}
        def to_s      = "#{kind}:#{name}"
      end

      # A single unit of work: an agent, a cognition processor, or a block.
      class StepNode < Base
        def agent      = opts[:agent]
        def cognition  = opts[:cognition]
        def block      = opts[:block]
        def input_fn   = opts[:input]
        def model      = opts[:model]

        # `on_error: :continue` lets a non-essential step fail without taking
        # the run down. The failure is still recorded on the step and in
        # telemetry — it is tolerated, not hidden.
        def on_error   = opts[:on_error]
        def tolerant?  = on_error.to_s == "continue"

        def executable? = !(agent || cognition || block).nil?
      end

      # Fan-out. `over` is a list of agents/roles or a lambda returning a
      # collection; every element becomes a child step.
      class ParallelNode < Base
        def over            = opts[:over]
        def with_fn         = opts[:with]
        def max_concurrency = opts[:max_concurrency]
        def as              = opts[:as] || name
        def agent           = opts[:agent]
      end

      # Fan-in barrier. `on:` decides when the continuation fires.
      class JoinNode < Base
        MODES = %i[all_complete all_settled any_complete].freeze

        def target     = opts[:target] || name
        def mode       = opts[:on] || :all_complete
        def quorum     = opts[:n]
        def on_timeout = opts[:on_timeout] || :fail
      end

      class MapNode < Base
        def over            = opts[:over]
        def agent           = opts[:agent]
        def block           = opts[:block]
        def max_concurrency = opts[:max_concurrency]
        def batch_size      = opts[:batch_size] || 1
      end

      # Tree reduce: `chunk` items at a time until a single value remains, so a
      # 400-fragment summary is ~3 levels, not a 400-step chain.
      class ReduceNode < Base
        def agent  = opts[:agent]
        def block  = opts[:block]
        def chunk  = opts[:chunk] || 5
        def target = opts[:target] || name
      end

      class LoopNode < Base
        def max        = opts[:max] || 3
        def until_fn   = opts[:until]
        def body       = opts[:body] || []
      end

      class RaceNode < Base
        def over          = opts[:over]
        def with_fn       = opts[:with]
        def cancel_losers = opts.fetch(:cancel_losers, true)
      end

      # Suspends the run until a human resolves the suggestion. v0.1 could not
      # express this: approving a suggestion ended a process instead of
      # continuing one.
      class HumanGateNode < Base
        def from_fn    = opts[:from]
        def assignee   = opts[:assignee]
        def on_timeout = opts[:on_timeout] || :fail
        def type       = opts[:type] || "flow_gate"
      end

      class SubFlowNode < Base
        def flow     = opts[:flow]
        def input_fn = opts[:input]
      end
    end

    # Compiled, immutable description of a flow class.
    class Definition
      attr_reader :flow_class, :nodes, :inputs, :compensations, :error_handlers,
                  :version, :queue, :timeout, :idempotency_fn

      def initialize(flow_class)
        @flow_class     = flow_class
        @nodes          = []
        @inputs         = []
        @compensations  = {}
        @error_handlers = []
        @version        = 1
        @queue          = nil
        @timeout        = nil
        @idempotency_fn = nil
      end

      def add_node(node)
        @nodes << node
        node
      end

      def set(key, value)
        instance_variable_set(:"@#{key}", value)
      end

      def add_input(*names)  = @inputs.concat(names.map(&:to_sym))
      def add_compensation(step, callable) = @compensations[step.to_sym] = callable
      def add_error_handler(handler)       = @error_handlers << handler

      def node(name)      = flatten_nodes.find { |n| n.name == name.to_sym }
      def node_names      = flatten_nodes.map(&:name)
      def flatten_nodes(list = @nodes)
        list.flat_map { |n| n.is_a?(Nodes::LoopNode) ? [n, *flatten_nodes(n.body)] : [n] }
      end

      def dup_for(subclass)
        copy = Definition.new(subclass)
        copy.instance_variable_set(:@nodes, @nodes.dup)
        copy.instance_variable_set(:@inputs, @inputs.dup)
        copy.instance_variable_set(:@compensations, @compensations.dup)
        copy.instance_variable_set(:@error_handlers, @error_handlers.dup)
        %i[version queue timeout idempotency_fn].each do |k|
          copy.set(k, instance_variable_get(:"@#{k}"))
        end
        copy
      end

      # ─── Static validation ───────────────────────────────────────────────────

      def validate!
        problems = validate
        raise FlowDefinitionError, "#{flow_class}: #{problems.join('; ')}" if problems.any?

        true
      end

      def validate
        problems = []
        seen = []

        flatten_nodes.each do |n|
          problems << "duplicate step name `#{n.name}`" if seen.include?(n.name)
          seen << n.name

          case n
          when Nodes::StepNode
            problems << "step `#{n.name}` has no agent, cognition or block" unless n.executable?
          when Nodes::JoinNode
            unless Nodes::JoinNode::MODES.include?(n.mode) || n.quorum
              problems << "join `#{n.name}` has unknown mode #{n.mode.inspect}"
            end
            fanout = flatten_nodes.find { |x| x.name == n.target && (x.is_a?(Nodes::ParallelNode) || x.is_a?(Nodes::MapNode)) }
            problems << "join `#{n.name}` has no matching parallel/map step" if fanout.nil?
          when Nodes::ParallelNode
            problems << "parallel `#{n.name}` needs `over:`" if n.over.nil?
          when Nodes::MapNode
            problems << "map `#{n.name}` needs `over:`" if n.over.nil?
            problems << "map `#{n.name}` needs an agent or block" unless n.agent || n.block
          when Nodes::ReduceNode
            problems << "reduce `#{n.name}` needs an agent or block" unless n.agent || n.block
            problems << "reduce `#{n.name}` has no matching map step" unless flatten_nodes.any? { |x| x.name == n.target && x.is_a?(Nodes::MapNode) }
          when Nodes::SubFlowNode
            problems << "sub_flow `#{n.name}` needs `flow:`" if n.flow.nil?
          when Nodes::LoopNode
            problems << "loop `#{n.name}` has an empty body" if n.body.empty?
          end
        end

        @compensations.each_key do |step|
          problems << "compensate references unknown step `#{step}`" unless seen.include?(step)
        end

        # Every fan-out should be joined, otherwise the results are never
        # collected and the "parallel" is just fire-and-forget.
        flatten_nodes.select { |n| n.is_a?(Nodes::ParallelNode) }.each do |p|
          joined = flatten_nodes.any? { |n| n.is_a?(Nodes::JoinNode) && n.target == p.name }
          problems << "parallel `#{p.name}` is never joined" unless joined
        end

        problems
      end
    end
  end
end
