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
        def effect    = (opts[:effect] || :read_only).to_sym
        def ordering  = (opts[:ordering] || :strict).to_sym
        def depends_on = Array(opts[:depends_on]).map(&:to_sym)
        def estimated_ms = [opts.fetch(:estimated_ms, 1).to_f, 0.0].max
        def estimated_cost = [opts.fetch(:estimated_cost, 0).to_f, 0.0].max
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
        def max_concurrency(ctx = nil)
          val = opts[:max_concurrency]
          val.respond_to?(:call) ? (ctx ? val.call(ctx) : val) : val
        end
        def as              = opts[:as] || name
        def agent           = opts[:agent]
        def branch_effect   = (opts[:branch_effect] || :read_only).to_sym
        def independence_key = opts[:independence_key]
        def conflict_key    = opts[:conflict_key] || independence_key
        def idempotency_key = opts[:idempotency_key]
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
        def max_concurrency(ctx = nil)
          val = opts[:max_concurrency]
          val.respond_to?(:call) ? (ctx ? val.call(ctx) : val) : val
        end
        def batch_size      = opts[:batch_size] || 1
        def branch_effect   = (opts[:branch_effect] || :read_only).to_sym
        def independence_key = opts[:independence_key]
        def conflict_key    = opts[:conflict_key] || independence_key
        def idempotency_key = opts[:idempotency_key]
      end

      # Tree reduce: `chunk` items at a time until a single value remains, so a
      # 400-fragment summary is ~3 levels, not a 400-step chain.
      class ReduceNode < Base
        def agent  = opts[:agent]
        def block  = opts[:block]
        def chunk  = opts[:chunk] || 5
        def target = opts[:target] || name
        def algebra = opts[:algebra]&.to_sym
        def commutative? = opts[:commutative] == true
        def contract_test = opts[:contract_test]
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
      EFFECTS = %i[read_only idempotent side_effecting].freeze
      ORDERINGS = %i[strict stable any].freeze
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

          problems << "step `#{n.name}` has unknown effect #{n.effect.inspect}" unless EFFECTS.include?(n.effect)
          problems << "step `#{n.name}` has unknown ordering #{n.ordering.inspect}" unless ORDERINGS.include?(n.ordering)

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
            if n.branch_effect == :side_effecting && n.idempotency_key.nil?
              problems << "parallel `#{n.name}` has side-effecting branches without an idempotency key"
            end
          when Nodes::MapNode
            problems << "map `#{n.name}` needs `over:`" if n.over.nil?
            problems << "map `#{n.name}` needs an agent or block" unless n.agent || n.block
            if n.branch_effect == :side_effecting && n.idempotency_key.nil?
              problems << "map `#{n.name}` has side-effecting branches without an idempotency key"
            end
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

      def plan_warnings
        warnings = []
        flatten_nodes.each do |node|
          if node.ordering == :any && node.depends_on.any?
            warnings << "#{node.name}: ordering:any contradicts explicit dependencies"
          end
          if node.is_a?(Nodes::ReduceNode) && node.commutative? && !node.contract_test.respond_to?(:call)
            warnings << "#{node.name}: commutative reducer has no contract test"
          end
          if (node.is_a?(Nodes::ParallelNode) || node.is_a?(Nodes::MapNode)) &&
             node.over.is_a?(Array) && node.conflict_key.respond_to?(:call)
            keys = node.over.map { |item| node.conflict_key.call(item) }
            duplicates = keys.group_by(&:itself).select { |_key, values| values.size > 1 }.keys
            warnings << "#{node.name}: fan-out shares conflict keys #{duplicates.map(&:inspect).join(', ')}" if duplicates.any?
          end
          if node.is_a?(Nodes::LoopNode) && (node.max.to_i <= 0 || !node.until_fn.respond_to?(:call))
            warnings << "#{node.name}: cycle needs a positive bound and exit condition"
          end
        rescue StandardError => error
          warnings << "#{node.name}: conflict analysis unavailable (#{error.class})"
        end
        warnings.sort
      end

      def explain_plan
        flat = flatten_nodes
        warnings = plan_warnings
        warnings.each do |warning|
          Telemetry.emit("flow.plan.warning",
                         dims: { flow: flow_class.name.to_s, warning: warning_code(warning) },
                         measures: { count: 1 })
        end
        node_rows = flat.map do |node|
          row = { name: node.name, kind: node.kind, effect: node.effect, ordering: node.ordering,
                  depends_on: node.depends_on, estimated_ms: node.estimated_ms,
                  estimated_cost: node.estimated_cost }
          row[:branch_effect] = node.branch_effect if node.respond_to?(:branch_effect)
          row[:algebra] = node.algebra if node.respond_to?(:algebra)
          row[:hitl] = true if node.is_a?(Nodes::HumanGateNode)
          row[:timeout] = node.timeout if node.timeout
          row
        end
        edges = flat.each_cons(2).map { |left, right| [left.name, right.name] }
        flat.each { |node| node.depends_on.each { |dependency| edges << [dependency, node.name] } }
        fanouts = flat.select { |node| node.is_a?(Nodes::ParallelNode) || node.is_a?(Nodes::MapNode) }
        fanout_sizes = fanouts.map { |node| node.over.is_a?(Array) ? node.over.size : nil }.compact
        joins = flat.grep(Nodes::JoinNode).map do |node|
          { name: node.name, target: node.target, mode: node.mode, timeout: node.timeout,
            partial_policy: node.on_timeout }
        end
        plan = {
          flow: flow_class.name.to_s, version: version,
          dag: { nodes: node_rows, edges: edges.uniq },
          estimated_critical_path_ms: estimated_critical_path(flat),
          max_fanout: fanout_sizes.max,
          fanout_budget: fanouts.sum { |node| static_concurrency(node) },
          joins: joins,
          effects: node_rows.to_h { |row| [row[:name], row[:effect]] },
          hitl_steps: flat.grep(Nodes::HumanGateNode).map(&:name),
          idempotent: !idempotency_fn.nil?,
          warnings: warnings,
          estimated_cost: node_rows.sum { |row| row[:estimated_cost] },
          estimated_wall_time_ms: estimated_critical_path(flat)
        }
        plan[:definition_digest] = graph_digest(plan)
        plan
      end

      private

      def estimated_critical_path(nodes)
        nodes.sum do |node|
          if (node.is_a?(Nodes::ParallelNode) || node.is_a?(Nodes::MapNode)) && node.over.is_a?(Array)
            node.estimated_ms
          elsif node.is_a?(Nodes::LoopNode)
            node.estimated_ms * node.max.to_i
          else
            node.estimated_ms
          end
        end.round(3)
      end

      def graph_digest(value)
        canonical = canonical_plan_value(value)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical))}"
      end

      def static_concurrency(node)
        value = node.max_concurrency(nil)
        value.respond_to?(:call) ? 0 : value.to_i
      end

      def warning_code(warning)
        case warning
        when /commutative reducer/ then "reducer_contract_missing"
        when /conflict keys/ then "fanout_conflict"
        when /ordering:any/ then "ordering_dependency_conflict"
        when /cycle needs/ then "cycle_contract_missing"
        else "analysis_unavailable"
        end
      end

      def canonical_plan_value(value)
        case value
        when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key.to_s, canonical_plan_value(item)] }
        when Array then value.map { |item| canonical_plan_value(item) }
        when Symbol then value.to_s
        when Proc then value.source_location&.join(":") || "callable"
        else value
        end
      end
    end
  end
end
