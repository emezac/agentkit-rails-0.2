# frozen_string_literal: true

require_relative "flow/definition"
require_relative "flow/coder"
require_relative "flow/context"
require_relative "flow/run"
require_relative "flow/executor"
require_relative "flow/dispatcher"
require_relative "flow/worker"

module Agentkit
  # Declarative orchestration.
  #
  #   class InvoiceOverdueFlow < Agentkit::Flow
  #     input :factura
  #     step     :observe, agent: PaymentMonitorAgent
  #     parallel :council, over: [FinanceBotAgent, AccountingBotAgent, CeoBotAgent],
  #                        with: ->(ctx) { ctx[:observe].memory }
  #     join     :council, on: :all_settled, timeout: 180
  #     step     :synthesize, agent: CouncilSynthesizerAgent
  #     human_gate :approve, timeout: 172_800, on_timeout: :auto_reject
  #     step     :apply, if: ->(ctx) { ctx[:approve].approved? }
  #   end
  #
  #   InvoiceOverdueFlow.call(factura: invoice)          # sync
  #   InvoiceOverdueFlow.perform_later(factura: invoice) # async
  class Flow
    class << self
      def definition
        @definition ||= superclass.respond_to?(:definition) && superclass != Agentkit::Flow ?
                          superclass.definition.dup_for(self) : Definition.new(self)
      end

      def inherited(subclass)
        super
        Registry.register(subclass)
      end

      # ─── DSL ───────────────────────────────────────────────────────────────

      def version(value = nil)
        return definition.version if value.nil?

        definition.set(:version, value)
      end

      def input(*names)          = definition.add_input(*names)
      def queue(value)           = definition.set(:queue, value)
      def timeout(value)         = definition.set(:timeout, value)
      def idempotency(callable)  = definition.set(:idempotency_fn, callable)

      def step(name, **opts, &block)
        collect(Nodes::StepNode.new(name, **opts, block: block))
      end

      def parallel(name, **opts)  = collect(Nodes::ParallelNode.new(name, **opts))

      def join(name, **opts)
        collect(Nodes::JoinNode.new(:"#{name}_join", target: name, **opts))
      end

      def map(name, **opts, &block)
        collect(Nodes::MapNode.new(name, **opts, block: block))
      end

      def reduce(name, **opts, &block)
        collect(Nodes::ReduceNode.new(:"#{name}_reduce", target: name, **opts, block: block))
      end

      def race(name, **opts)      = collect(Nodes::RaceNode.new(name, **opts))
      def human_gate(name, **opts) = collect(Nodes::HumanGateNode.new(name, **opts))
      def sub_flow(name, **opts)   = collect(Nodes::SubFlowNode.new(name, **opts))

      def loop_until(name, max: 3, **opts, &block)
        previous  = @collector
        body      = []
        @collector = body
        instance_eval(&block)
        @collector = previous
        collect(Nodes::LoopNode.new(name, max: max, body: body, **opts))
      end

      def on_error(handler = nil, &block)
        definition.add_error_handler(handler.is_a?(Symbol) ? ->(ctx, err) { send(handler, ctx, err) } : (block || handler))
      end

      def compensate(step_name, with:)
        definition.add_compensation(step_name, with)
      end

      # Validates the graph. Called by `Flow.validate_all!` at boot so a broken
      # flow surfaces on deploy, not on the first production run.
      def validate! = definition.validate!

      # ─── Execution ─────────────────────────────────────────────────────────

      def call(context: nil, executor: nil, **input)
        ctx   = context || Context.resolve
        store = store_for
        mode  = executor || :sync

        if (existing = find_existing(store, input))
          return Result.ok(existing.output&.dig(:result), run: existing)
        end

        run = build_run(ctx, input, store)
        result = Executor.new(definition: definition, run: run, store: store,
                              context: ctx, input: input, mode: mode).call
        decorate(result, run)
      end

      # Enqueues the run and returns immediately. The dispatcher decides how the
      # work is delivered; with `:inline` (no job backend) it executes now
      # rather than silently dropping the work.
      def perform_later(context: nil, **input)
        ctx   = context || Context.resolve
        store = store_for

        if (existing = find_existing(store, input))
          return existing
        end

        run = build_run(ctx, input, store)
        Flow.dispatcher.advance(run.run_id)
        run
      end

      # Resume a run suspended at a human gate or a join.
      def resume(run_id, context: nil, mode: nil)
        store = store_for
        run   = store.find_run_by_uuid(run_id) || store.find_run(run_id)
        raise FlowError, "Run #{run_id} not found" if run.nil?
        return Result.ok(run.output) if run.finished?

        ctx = context || Context.resolve
        Executor.new(definition: definition, run: run, store: store,
                     context: ctx, input: run.input,
                     mode: mode || (Flow.dispatcher.async? ? :async : :sync)).call
      end

      # One store per process, not per flow class: a run must be findable from
      # any entry point (job, controller, console) regardless of which subclass
      # created it.
      def store_for
        Flow.shared_store
      end

      def store=(store)
        Flow.shared_store = store
      end

      private

      def collect(node)
        (@collector || definition.nodes) << node
        node
      end

      def build_run(ctx, input, store)
        run = Run.new(
          flow_name: name, flow_version: definition.version, run_id: ctx.run_id,
          input: input, context: ctx.to_h, tenant_key: ctx.tenant_key,
          account_id: id_of(ctx.account), user_id: id_of(ctx.user),
          idempotency_key: definition.idempotency_fn&.call(input),
          deadline_at: definition.timeout ? Time.now + definition.timeout : nil,
          steps_total: definition.flatten_nodes.size
        )
        store.create_run(run)
        run
      end

      def find_existing(store, input)
        key = definition.idempotency_fn&.call(input)
        return nil if key.nil?

        existing = store.find_by_idempotency(key)
        existing&.finished? ? existing : nil
      end

      def decorate(result, run)
        result.with_metadata(run: run)
      end

      def id_of(obj) = obj.respond_to?(:id) ? obj.id : obj
    end

    # Registry of every defined flow — powers `validate_all!`, the dashboard and
    # the job that re-instantiates a flow class from a persisted run.
    module Registry
      class << self
        def all = @all ||= []

        def register(klass)
          all << klass unless all.include?(klass)
          klass
        end

        def find(name)
          all.find { |k| k.name == name } || (Object.const_get(name) rescue nil)
        end

        def validate_all!
          problems = all.flat_map { |k| k.definition.validate.map { |p| "#{k.name}: #{p}" } }
          raise FlowDefinitionError, problems.join("\n") if problems.any?

          true
        end

        def reset! = @all = []
      end
    end

    class << self
      def shared_store
        @shared_store ||= Store.build(Agentkit.config.flow.store)
      end

      def dispatcher
        @dispatcher ||= Dispatcher.build(Agentkit.config.flow.dispatcher)
      end

      attr_writer :shared_store, :dispatcher
    end

    # Test switch: sync executor, fake LLM, in-memory stores.
    def self.test_mode!
      @shared_store = nil
      @dispatcher   = nil
      Agentkit.config.flow.executor   = :sync
      Agentkit.config.flow.dispatcher = :inline
      Agentkit.config.flow.store      = :memory
      Agentkit.config.memory.store  = :memory
      Agentkit.config.llm.adapter   = :fake
      Agentkit.config.telemetry.backends = [:memory]
      LLM.reset!
      Memory.reset!
      Telemetry.reset!
      true
    end
  end
end
