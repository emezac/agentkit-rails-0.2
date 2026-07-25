# frozen_string_literal: true

module Agentkit
  class Flow
    # Walks the compiled graph. One definition, two modes:
    #
    #   :sync  — everything in this process. Branches run inline, a join is
    #            immediate, a human gate raises. For requests, demos and specs.
    #   :async — each fan-out branch becomes its own job, the barrier is
    #            released by whichever worker finishes last, and the run
    #            SUSPENDS at a join or a gate instead of blocking a worker.
    #
    # Both re-walk the graph from the top on every entry: completed steps replay
    # from their persisted output instead of executing again. That is what makes
    # a run resumable from any crash point — the executor holds no state that
    # isn't in the database.
    class Executor
      # Raised internally to stop the walk. Never escapes `call`.
      class Suspended < FlowError
        attr_reader :reason, :step_name

        def initialize(reason, step_name = nil)
          @reason    = reason
          @step_name = step_name
          super("suspended: #{reason} at #{step_name}")
        end
      end

      attr_reader :definition, :run, :store, :flow_ctx, :mode

      def initialize(definition:, run:, store:, context:, input:, mode: nil)
        @definition = definition
        @run        = run
        @store      = store
        @context    = context
        @mode       = (mode || Agentkit.config.flow.executor).to_sym
        @flow_ctx   = FlowContext.new(input: input, run: run, context: context)
        @completed  = []          # for compensation, in execution order
        @position   = 0
      end

      def async? = @mode == :async

      def call
        store.update_run(run, status: "running", started_at: run.started_at || Time.now)
        Telemetry.emit("flow.run.started", dims: { flow: run.flow_name, version: run.flow_version })

        execute_nodes(definition.nodes)
        finish(:completed)
      rescue Suspended => e
        suspend_run(e)
      rescue RunCancelled
        finish(:cancelled)
      rescue StepFailed => e
        handle_failure(e)
      end

      private

      # ─── Node dispatch ───────────────────────────────────────────────────────

      def execute_nodes(nodes, iteration: nil)
        nodes.each { |node| execute_node(node, iteration: iteration) }
      end

      def execute_node(node, iteration: nil)
        raise RunCancelled if run.status == "cancelled"
        raise RunTimedOut, "run deadline exceeded" if run.timed_out?

        case node
        when Nodes::StepNode      then run_step(node, iteration)
        when Nodes::ParallelNode  then run_parallel(node, iteration)
        when Nodes::JoinNode      then run_join(node, iteration)
        when Nodes::MapNode       then run_map(node, iteration)
        when Nodes::ReduceNode    then run_reduce(node, iteration)
        when Nodes::LoopNode      then run_loop(node)
        when Nodes::RaceNode      then run_race(node, iteration)
        when Nodes::HumanGateNode then run_human_gate(node, iteration)
        when Nodes::SubFlowNode   then run_sub_flow(node, iteration)
        else raise FlowError, "Unknown node type #{node.class}"
        end
      end

      # ─── step ────────────────────────────────────────────────────────────────

      def run_step(node, iteration)
        return skip(node, iteration) unless passes_guard?(node)

        step, fresh = checkout(node, iteration)
        return replay(node, step) unless fresh

        input = resolve_input(node.input_fn)

        result =
          begin
            with_retries(node, step) { invoke(node, input) }
          rescue StepFailed => e
            raise unless node.respond_to?(:tolerant?) && node.tolerant?

            Telemetry.emit("flow.step.tolerated",
                           dims: { flow: run.flow_name, step: node.name },
                           measures: { count: 1 })
            Result.err(e.cause_error || e, tolerated: true)
          end

        return tolerate(node, step, result) if result.err? && node.respond_to?(:tolerant?) && node.tolerant?

        complete_step(node, step, result)
      end

      # A tolerated failure completes the step with a null value so downstream
      # guards can see it, instead of unwinding the run.
      def tolerate(node, step, result)
        store.update_step(step, status: "failed", finished_at: Time.now,
                                error: result.error.to_s,
                                output: { "result" => Coder.dump(Result.ok(nil), store: store) })
        flow_ctx.set(node.name, Result.ok(nil, tolerated: true, error: result.error.to_s))
        emit_step(node, step, result)
        flow_ctx[node.name]
      end

      # ─── parallel / join ─────────────────────────────────────────────────────

      # The barrier row is created with pending_count = N before any branch
      # starts. Each branch decrements it atomically as it closes; the one that
      # reaches zero releases the join.
      def run_parallel(node, iteration)
        return skip(node, iteration) unless passes_guard?(node)

        barrier, fresh = checkout(node, iteration, kind: "parallel")
        return replay_fanout(node, barrier) unless fresh

        branches = resolve_branches(node)
        payload  = resolve_input(node.with_fn)
        store.update_step(barrier, pending_count: branches.size, status: "running",
                                   started_at: Time.now)

        children = branches.each_with_index.map do |(key, target), index|
          create_branch_step(node, barrier, key: key, target: target,
                                            payload: payload, index: index)
        end

        if async?
          dispatch_async(node, barrier, children)
          raise Suspended.new(:waiting_join, node.name)
        end

        pairs = run_branches_inline(node, barrier, children)
        store.update_step(barrier, status: "completed", finished_at: Time.now,
                                   output: { "branches" => pairs.size })
        flow_ctx.set(node.as, StepResults.new(pairs))
        @completed << [node, barrier]
        pairs
      end

      def create_branch_step(node, barrier, key:, target:, payload:, index:)
        child_key = "#{barrier.step_key}:#{key}:#{index}"
        step, _fresh = store.find_or_create_step(
          run, step_key: child_key, step_name: node.name.to_s, kind: "branch",
          parent_step_id: barrier.id, position: next_position,
          input: { "key" => key.to_s, "index" => index,
                   "target" => target.is_a?(Class) ? target.name : nil,
                   "payload" => Coder.dump(payload, store: store) }
        )
        step
      end

      def dispatch_async(node, barrier, children)
        children.each { |child| Flow.dispatcher.branch(run.run_id, child.id) unless child.settled? }

        join = definition.flatten_nodes.find { |n| n.is_a?(Nodes::JoinNode) && n.target == node.name }
        return if join.nil?

        Flow.dispatcher.join_timeout(
          run.run_id, barrier.id,
          delay: join.timeout || Agentkit.config.flow.default_join_timeout,
          policy: join.on_timeout
        )
      end

      def run_branches_inline(node, barrier, children)
        mapper = lambda do |child|
          next [child.input["key"], decode_result(child)] if child.settled?

          payload = Coder.load(child.input["payload"], store: store)
          target  = Worker.resolve_branch_target(node, child)
          result  = execute_branch(node, target, payload)
          store.close_and_decrement(child, barrier,
                                    status: result.ok? ? "completed" : "failed",
                                    output: { "result" => Coder.dump(result, store: store) })
          emit_step(node, child, result)
          [child.input["key"], result]
        end

        if Agentkit.config.flow.sync_threads && children.size > 1
          run_threaded(children, mapper)
        else
          children.map { |c| mapper.call(c) }
        end
      end

      def run_join(node, iteration)
        barrier = find_barrier(node.target)
        raise FlowError, "join `#{node.name}` found no barrier for `#{node.target}`" if barrier.nil?

        # The join timed out under an :compensate policy — fail here so the
        # saga unwinds through the normal failure path.
        if barrier.status.to_s == "timed_out"
          raise StepFailed.new("join `#{node.name}` timed out", step: node.name)
        end

        # Async: the branches are still out there. Stop walking; the last one to
        # finish will call advance again and we resume right here.
        if barrier.pending_count.to_i.positive?
          Telemetry.emit("flow.join.waiting",
                         dims: { flow: run.flow_name, step: node.name },
                         measures: { pending: barrier.pending_count.to_i })
          raise Suspended.new(:waiting_join, node.name)
        end

        results = flow_ctx[node.target] || rebuild_results(barrier)
        step, fresh = checkout(node, iteration, kind: "join")
        return replay(node, step) unless fresh

        outcome = evaluate_join(node, results)
        Telemetry.emit("flow.join.resolve",
                       dims: { flow: run.flow_name, step: node.name, mode: node.mode,
                               partial: partial?(barrier, results) },
                       measures: { branches: results.size, failed: results.failed.size })

        complete_step(node, step, outcome)
      end

      def evaluate_join(node, results)
        case node.mode
        when :any_complete
          results.find(&:ok?) || Result.err(FlowError.new("no branch succeeded"))
        when :all_settled
          Result.ok(results, usage: results.usage)
        else
          results.ok? ? Result.ok(results, usage: results.usage) : Result.err(results.errors.first)
        end
      end

      def partial?(barrier, results)
        run.children_of(barrier.id).count { |c| c.status == "cancelled" }.positive? ||
          results.failed.any?
      end

      # ─── map / reduce ────────────────────────────────────────────────────────

      def run_map(node, iteration)
        return skip(node, iteration) unless passes_guard?(node)

        barrier, fresh = checkout(node, iteration, kind: "map")
        return replay_fanout(node, barrier) unless fresh

        items   = Array(resolve_input(node.over))
        batches = node.batch_size > 1 ? items.each_slice(node.batch_size).to_a : items
        store.update_step(barrier, pending_count: batches.size, status: "running",
                                   started_at: Time.now)

        children = batches.each_with_index.map do |item, index|
          create_branch_step(node, barrier, key: index, target: node.agent,
                                            payload: item, index: index)
        end

        if async?
          dispatch_async(node, barrier, children)
          raise Suspended.new(:waiting_join, node.name)
        end

        pairs = children.map do |child|
          next [child.input["index"], decode_result(child)] if child.settled?

          payload = Coder.load(child.input["payload"], store: store)
          result  = Result.capture { invoke_callable(node.agent, node.block, payload) }
          store.close_and_decrement(child, barrier,
                                    status: result.ok? ? "completed" : "failed",
                                    output: { "result" => Coder.dump(result, store: store) })
          [child.input["index"], result]
        end

        store.update_step(barrier, status: "completed", finished_at: Time.now)
        flow_ctx.set(node.name, StepResults.new(pairs))
        @completed << [node, barrier]
        pairs
      end

      # Tree reduce: chunk, reduce, repeat. 400 items is ~3 levels, not a chain.
      def run_reduce(node, iteration)
        source = flow_ctx[node.target] || rebuild_results(find_barrier(node.target))
        raise FlowError, "reduce `#{node.name}` found no map results for `#{node.target}`" if source.nil?

        step, fresh = checkout(node, iteration, kind: "reduce")
        return replay(node, step) unless fresh

        values = source.values
        level  = 0
        while values.size > 1
          level += 1
          values = values.each_slice(node.chunk).map { |group| invoke_callable(node.agent, node.block, group) }
        end

        result = Result.ok(values.first, usage: source.usage)
        Telemetry.emit("flow.reduce", dims: { flow: run.flow_name, step: node.name },
                                      measures: { levels: level, inputs: source.size })
        complete_step(node, step, result)
      end

      # ─── loop ────────────────────────────────────────────────────────────────

      def run_loop(node)
        iterations = 0
        node.max.times do |i|
          iterations = i + 1
          execute_nodes(node.body, iteration: iterations)
          break if node.until_fn && truthy?(node.until_fn.call(flow_ctx))
        end
        flow_ctx.set(node.name, Result.ok(iterations: iterations, converged: iterations < node.max))
        Telemetry.emit("flow.loop", dims: { flow: run.flow_name, step: node.name },
                                    measures: { iterations: iterations })
      end

      # ─── race ────────────────────────────────────────────────────────────────

      def run_race(node, iteration)
        step, fresh = checkout(node, iteration, kind: "race")
        return replay(node, step) unless fresh

        payload = resolve_input(node.with_fn)
        winner  = nil
        resolve_branches(node).each do |(_key, target)|
          candidate = Result.capture { invoke_callable(target, nil, payload) }
          next unless candidate.ok?

          winner = candidate
          break
        end
        complete_step(node, step, winner || Result.err(FlowError.new("all racers failed")))
      end

      # ─── human gate ──────────────────────────────────────────────────────────

      # Deliberately not `replay`-guarded: a resumed run re-enters the same gate
      # and re-reads the suggestion. That is how an approval continues a process
      # instead of ending one.
      def run_human_gate(node, iteration)
        return skip(node, iteration) unless passes_guard?(node)

        step, = checkout(node, iteration, kind: "human_gate")
        gate_key   = "#{run.run_id}:#{node.name}"
        suggestion = node.from_fn ? resolve_input(node.from_fn) : nil
        suggestion ||= HITL.by_gate_key(gate_key) || create_gate_suggestion(node, gate_key)

        if suggestion.resolved?
          Telemetry.emit("flow.human_gate.resolved",
                         dims: { flow: run.flow_name, step: node.name,
                                 approved: suggestion.accepted? })
          flow_ctx.set(node.name, GateResult.new(suggestion))
          store.update_step(step, status: "completed", finished_at: Time.now,
                                  output: { "result" => { "approved" => suggestion.accepted? } })
          @completed << [node, step]
          return Result.ok(suggestion)
        end

        store.update_step(step, status: "pending",
                                timeout_at: node.timeout ? Time.now + node.timeout : nil)
        raise Suspended.new(:waiting_human, node.name)
      end

      def create_gate_suggestion(node, gate_key)
        HITL.suggest!(
          type: node.type, title: "Approval required: #{node.name}",
          description: "Flow #{run.flow_name} is waiting at gate `#{node.name}`.",
          source_agent: run.flow_name, gate_key: gate_key, context: @context,
          idempotency_key: gate_key,
          payload: { "flow" => run.flow_name, "run_id" => run.run_id, "step" => node.name.to_s }
        )
      end

      # ─── sub flow ────────────────────────────────────────────────────────────

      def run_sub_flow(node, iteration)
        step, fresh = checkout(node, iteration, kind: "sub_flow")
        return replay(node, step) unless fresh

        input  = resolve_input(node.input_fn) || {}
        result = node.flow.call(**(input.is_a?(Hash) ? input : { value: input }),
                                context: @context.derive(trace_id: @context.trace_id))
        complete_step(node, step, result)
      end

      # ─── shared plumbing ─────────────────────────────────────────────────────

      def checkout(node, iteration, kind: nil, **attrs)
        key = step_key(node, iteration)
        store.find_or_create_step(run, step_key: key, step_name: node.name.to_s,
                                       kind: kind || node.kind, position: next_position, **attrs)
      end

      def step_key(node, iteration)
        iteration ? "#{node.name}:#{iteration}" : node.name.to_s
      end

      def find_barrier(name)
        run.steps_named(name).find { |s| %w[parallel map].include?(s.kind) }
      end

      # A step that already exists is a replay: reuse its recorded output rather
      # than running the body again.
      def replay(node, step)
        value = decode_output(step)
        flow_ctx.set(node.name, value) unless flow_ctx.key?(node.name)
        Telemetry.emit("flow.step.replayed", dims: { flow: run.flow_name, step: node.name })
        @completed << [node, step] if step.completed?
        value
      end

      # Replaying a fan-out rebuilds the StepResults from the children rows, so a
      # resumed run sees exactly what the original walk saw.
      def replay_fanout(node, barrier)
        results = rebuild_results(barrier)
        key     = node.respond_to?(:as) ? node.as : node.name
        flow_ctx.set(key, results)
        Telemetry.emit("flow.step.replayed", dims: { flow: run.flow_name, step: node.name })
        @completed << [node, barrier] if barrier.completed?
        results
      end

      def rebuild_results(barrier)
        return nil if barrier.nil?

        children = run.children_of(barrier.id).sort_by { |c| c.input["index"].to_i }
        pairs = children.reject { |c| c.status == "cancelled" }
                        .map { |c| [c.input["key"] || c.input["index"], decode_result(c)] }
        StepResults.new(pairs)
      end

      def decode_result(step)
        decoded = Coder.load(step.raw_result, store: store)
        decoded.is_a?(Result) ? decoded : Result.wrap(decoded)
      end
      alias decode_output decode_result

      def skip(node, iteration)
        step, fresh = checkout(node, iteration)
        store.update_step(step, status: "skipped", finished_at: Time.now) if fresh
        flow_ctx.set(node.name, Result.ok(nil, skipped: true))
        Telemetry.emit("flow.step.skipped", dims: { flow: run.flow_name, step: node.name })
        nil
      end

      def with_retries(node, step)
        spec     = node.retry_spec
        attempts = spec[:attempts] || 1
        on       = Array(spec[:on] || [TransientError])
        tries    = 0

        begin
          tries += 1
          started = monotonic
          result  = yield
          step.record_attempt(duration_ms: ((monotonic - started) * 1000).round)
          raise StepFailed.new(result.error.to_s, step: node.name, cause_error: result.error) if result.err? && !result.retryable?

          if result.err? && result.retryable? && tries < attempts
            sleep(backoff(tries, spec))
            raise Retry
          end
          result
        rescue Retry
          retry
        rescue StandardError => e
          raise if e.is_a?(StepFailed) || e.is_a?(Suspended) || e.is_a?(RunCancelled)

          step.record_attempt(error: e)
          if tries < attempts && on.any? { |k| e.is_a?(k) }
            sleep(backoff(tries, spec))
            retry
          end
          store.update_step(step, status: "failed", finished_at: Time.now, error: e.message,
                                  attempt_count: step.attempt_count, attempts: step.attempts)
          raise StepFailed.new("step `#{node.name}` failed: #{e.message}", step: node.name, cause_error: e)
        end
      end

      class Retry < StandardError; end

      def complete_step(node, step, result)
        store.update_step(step, status: result.ok? ? "completed" : "failed",
                                finished_at: Time.now,
                                output: { "result" => Coder.dump(result, store: store) },
                                usage: result.usage&.to_h || {},
                                attempt_count: step.attempt_count, attempts: step.attempts)
        flow_ctx.set(node.name, result)
        @completed << [node, step] if result.ok?
        store.update_run(run,
                         cost_usd: run.cost_usd.to_f + (result.usage&.cost_usd || 0.0),
                         steps_completed: run.steps_completed.to_i + 1)
        emit_step(node, step, result)
        raise StepFailed.new(result.error.to_s, step: node.name, cause_error: result.error) if result.err?

        result
      end

      def emit_step(node, step, result)
        Telemetry.emit("flow.step.completed",
                       dims: { flow: run.flow_name, step: node.name, kind: node.kind,
                               status: result.ok? ? "ok" : "error" },
                       measures: { duration_ms: step.duration_ms || 0,
                                   attempts: step.attempt_count,
                                   cost_usd: result.usage&.cost_usd || 0.0 })
      end

      def invoke(node, input)
        return Result.wrap(Cognition.run(node.cognition, input: input, context: @context)) if node.cognition

        Result.capture { invoke_callable(node.agent, node.block, input) }
      end

      def invoke_callable(agent, block, input)
        return block.arity.zero? ? block.call : block.call(input.nil? ? flow_ctx : input) if block
        return agent.call(input, context: @context) if agent.respond_to?(:call) && !agent.is_a?(Class)

        instance = agent.respond_to?(:new) ? agent.new(context: @context) : agent
        args = instance.method(:call).arity.zero? ? [] : [input]
        instance.call(*args)
      end

      def execute_branch(node, target, payload)
        Result.capture { invoke_callable(node.agent || target, nil, payload) }
      end

      def resolve_branches(node)
        source = node.over
        list   = source.respond_to?(:call) ? source.call(flow_ctx) : source
        Array(list).map { |item| [branch_key(item), item] }
      end

      def branch_key(item)
        return item.name.to_s.split("::").last if item.is_a?(Class)
        return item.to_s if item.is_a?(Symbol) || item.is_a?(String)

        item.respond_to?(:id) ? "item#{item.id}" : item.object_id.to_s
      end

      def resolve_input(fn)
        return nil if fn.nil?

        fn.respond_to?(:call) ? fn.call(flow_ctx) : fn
      end

      def passes_guard?(node)
        ok = node.guard.nil? || truthy?(node.guard.call(flow_ctx))
        ok &&= !truthy?(node.unless_guard.call(flow_ctx)) if node.unless_guard
        ok
      end

      def run_threaded(items, mapper)
        parent = Context.current
        items.map do |item|
          Thread.new do
            Context.current = parent
            mapper.call(item)
          end
        end.map(&:value)
      end

      # ─── finish / suspend / compensate ───────────────────────────────────────

      def finish(status)
        last   = flow_ctx.last
        output = last.respond_to?(:value) ? last&.value : last
        store.update_run(run, status: status.to_s, finished_at: Time.now,
                              output: { "result" => Coder.dump(last, store: store) })
        Telemetry.emit("flow.run.#{status}",
                       dims: { flow: run.flow_name, version: run.flow_version },
                       measures: { steps: run.steps.size, cost_usd: run.cost_usd.to_f,
                                   duration_ms: run.started_at ? ((Time.now - run.started_at) * 1000).round : 0 })
        status == :completed ? Result.ok(output, usage: flow_ctx.usage) : Result.err(FlowError.new(status.to_s))
      end

      def suspend_run(suspension)
        status = suspension.reason == :waiting_human ? "waiting_human" : "waiting_join"
        store.update_run(run, status: status)
        Telemetry.emit("flow.run.suspended",
                       dims: { flow: run.flow_name, step: suspension.step_name, reason: suspension.reason })

        # Sync callers get the historical exception so a controller can render
        # "waiting for approval"; async callers just see the parked run.
        error = suspension.reason == :waiting_human ?
                  PendingHumanApproval.new(run: run, step_name: suspension.step_name) :
                  suspension
        Result.err(error, retryable: false)
      end

      # Saga: undo completed steps in reverse order.
      def handle_failure(error)
        store.update_run(run, status: "failed", error: { message: error.message },
                              finished_at: Time.now)
        definition.error_handlers.each { |h| safely { h.call(flow_ctx, error) } }

        if definition.compensations.any?
          store.update_run(run, status: "compensating")
          @completed.reverse_each do |(node, _step)|
            comp = definition.compensations[node.name]
            next if comp.nil?

            safely { comp.call(flow_ctx) }
            Telemetry.emit("flow.compensated", dims: { flow: run.flow_name, step: node.name })
          end
          store.update_run(run, status: "compensated")
        end

        Telemetry.emit("flow.run.failed",
                       dims: { flow: run.flow_name, step: error.respond_to?(:step) ? error.step : nil },
                       measures: { steps: run.steps.size, cost_usd: run.cost_usd.to_f })
        Result.err(error)
      end

      def safely
        yield
      rescue StandardError => e
        Agentkit.logger&.error("[AgentKit::Flow] handler failed: #{e.message}")
      end

      def backoff(attempt, spec)
        base = spec[:backoff] == :exponential ? 0.1 * (2**(attempt - 1)) : 0.05
        base * (0.5 + Kernel.rand)
      end

      def next_position = (@position += 1)
      def truthy?(value) = !!value && value != :false
      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Wrapper so `ctx[:approve].approved?` reads naturally in a guard.
    class GateResult < Result
      def initialize(suggestion)
        @suggestion = suggestion
        super(ok: true, value: suggestion)
      end

      attr_reader :suggestion

      def approved? = @suggestion.accepted?
      def rejected? = @suggestion.status.to_s == "rejected"
    end
  end
end
