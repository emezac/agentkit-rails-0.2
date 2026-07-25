# frozen_string_literal: true

module Agentkit
  class Flow
    # The three entry points a job backend calls. They live here, not in the
    # ActiveJob classes, so the async path is testable without Rails: the test
    # dispatcher drives exactly the same code a Sidekiq worker would.
    #
    # The advance loop is a fixed point over persisted state, not a chain of
    # nested continuations — that is what lets a run resume from any crash point
    # by simply re-reading the database.
    module Worker
      module_function

      # Walk the graph as far as it can go, then stop. Called on start, after a
      # barrier releases, and after a human gate resolves.
      def advance(run_uuid)
        store = Flow.shared_store
        run   = store.find_run_by_uuid(run_uuid)
        return log("run #{run_uuid} not found") if run.nil?
        return if run.finished?

        flow = Registry.find(run.flow_name)
        return log("flow #{run.flow_name} is not loaded") if flow.nil?

        Executor.new(definition: flow.definition, run: run, store: store,
                     context: rebuild_context(run), input: run.input, mode: :async).call
      end

      # One branch of a fan-out. Everything it needs is in its own step row, so
      # it can execute on any worker without the parent still being alive.
      def run_branch(run_uuid, step_id)
        store = Flow.shared_store
        run   = store.find_run_by_uuid(run_uuid)
        return log("run #{run_uuid} not found") if run.nil?

        step = store.find_step(run, step_id)
        return log("step #{step_id} not found") if step.nil?

        # Redelivery: the step already closed. Do NOT execute and do NOT
        # decrement the barrier a second time.
        if step.settled?
          Telemetry.emit("flow.branch.redelivered",
                         dims: { flow: run.flow_name, step: step.step_name })
          return
        end

        barrier = store.find_step(run, step.parent_step_id)
        flow    = Registry.find(run.flow_name)
        node    = flow&.definition&.node(step.step_name)
        return log("node #{step.step_name} missing") if node.nil?

        ctx    = rebuild_context(run)
        result = Agentkit.with_context(ctx) { execute_branch(node, step, ctx, store) }

        remaining = store.close_and_decrement(
          step, barrier,
          status: result.ok? ? "completed" : "failed",
          output: { "result" => Coder.dump(result, store: store) }
        )

        Telemetry.emit("flow.branch.completed",
                       dims: { flow: run.flow_name, step: step.step_name,
                               status: result.ok? ? "ok" : "error" },
                       measures: { remaining: remaining.to_i })

        # "Last one turns off the lights": exactly one branch sees zero and
        # releases the join. No polling, no arbitrary delay.
        Flow.dispatcher.advance(run_uuid) if remaining && remaining <= 0
      end

      # Fired once per join, scheduled at fan-out time.
      def join_timeout(run_uuid, step_id, policy = "fail")
        store   = Flow.shared_store
        run     = store.find_run_by_uuid(run_uuid)
        return if run.nil? || run.finished?

        barrier = store.find_step(run, step_id)
        return if barrier.nil? || barrier.pending_count.to_i <= 0 # already released

        Telemetry.emit("flow.join.timeout",
                       dims: { flow: run.flow_name, step: barrier.step_name, policy: policy },
                       measures: { pending: barrier.pending_count.to_i })

        cancel_stragglers(run, barrier, store)

        case policy.to_s
        when "continue_with_partial"
          store.update_step(barrier, pending_count: 0, status: "completed", finished_at: Time.now)
          Flow.dispatcher.advance(run_uuid)
        when "compensate"
          # Route the failure back through the executor so `on_error` handlers
          # and the saga compensations actually run. Marking the run failed here
          # would skip both.
          store.update_step(barrier, pending_count: 0, status: "timed_out", finished_at: Time.now)
          Flow.dispatcher.advance(run_uuid)
        else # :fail — stop now, no compensation
          store.update_step(barrier, pending_count: 0, status: "timed_out", finished_at: Time.now)
          store.update_run(run, status: "failed", finished_at: Time.now,
                                error: { reason: "join timeout", step: barrier.step_name })
        end
      end

      # A branch that reports after the timeout must not resurrect the barrier.
      def cancel_stragglers(run, barrier, store)
        run.children_of(barrier.id).reject(&:settled?).each do |child|
          store.update_step(child, status: "cancelled", finished_at: Time.now)
        end
      end

      # ─── helpers ─────────────────────────────────────────────────────────────

      def execute_branch(node, step, ctx, store)
        payload = Coder.load(step.input["payload"], store: store)
        target  = resolve_branch_target(node, step)

        Result.capture { invoke_target(target, node, payload, ctx, step) }
      end

      def invoke_target(target, node, payload, ctx, step)
        return node.block.call(payload) if target.nil? && node.respond_to?(:block) && node.block
        raise FlowError, "branch #{step.step_key} has no callable target" if target.nil?
        return target.call(payload, context: ctx) if target.respond_to?(:call) && !target.is_a?(Class)

        instance = target.respond_to?(:new) ? target.new(context: ctx) : target
        instance.method(:call).arity.zero? ? instance.call : instance.call(payload)
      end

      # Resolution order matters. The node itself is the source of truth — that
      # keeps anonymous classes working in-process. The serialized class name is
      # the fallback for the case the node cannot answer: a different worker
      # process, where `over:` was a lambda whose result is gone.
      def resolve_branch_target(node, step)
        index = step.input["index"].to_i
        over  = node.respond_to?(:over) ? node.over : nil
        return over[index] if over.is_a?(Array) && over[index]
        return node.agent if node.respond_to?(:agent) && node.agent

        name = step.input["target"]
        return nil if name.nil?

        begin
          Object.const_get(name)
        rescue NameError
          raise FlowError, "branch target #{name} is not resolvable in this process"
        end
      end

      def rebuild_context(run)
        Context.new(run_id: run.run_id, trace_id: run.context["trace_id"] || run.run_id,
                    tenant_key: run.tenant_key,
                    metadata: { resumed: true })
      end

      def log(message)
        Agentkit.logger&.warn("[AgentKit::Flow::Worker] #{message}")
        nil
      end
    end
  end
end
