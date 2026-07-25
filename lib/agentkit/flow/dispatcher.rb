# frozen_string_literal: true

module Agentkit
  class Flow
    # Where the work actually goes. The engine never talks to ActiveJob or
    # Sidekiq directly: it asks the dispatcher to advance a run, run a branch or
    # schedule a join timeout.
    #
    # Three implementations, all speaking the same four calls:
    #   :inline     — run it now, in this process (sync executor, console, specs)
    #   :active_job — enqueue (production)
    #   :test       — record it; the spec drains the queue in whatever order it
    #                 likes, including out of order and twice, which is the only
    #                 honest way to prove the barrier and the idempotency.
    module Dispatcher
      def self.build(name)
        case name.to_sym
        when :inline     then Inline.new
        when :active_job then ActiveJobDispatcher.new
        when :test       then TestQueue.new
        else raise ConfigurationError, "Unknown flow dispatcher: #{name}"
        end
      end

      class Base
        def advance(run_uuid)                      = raise NotImplementedError
        def branch(run_uuid, step_id)              = raise NotImplementedError
        def join_timeout(run_uuid, step_id, delay:, policy:) = raise NotImplementedError
        def async? = true
      end

      # Executes immediately. Used by the sync executor and as the fallback when
      # no job backend is loaded — better than silently dropping the work.
      class Inline < Base
        def advance(run_uuid)         = Worker.advance(run_uuid)
        def branch(run_uuid, step_id) = Worker.run_branch(run_uuid, step_id)

        # Nothing to schedule: an inline run cannot outlive its own call.
        def join_timeout(*, **) = nil
        def async? = false
      end

      class ActiveJobDispatcher < Base
        def advance(run_uuid)
          Agentkit::FlowAdvanceJob.perform_later(run_uuid)
        end

        def branch(run_uuid, step_id)
          Agentkit::FlowBranchJob.perform_later(run_uuid, step_id)
        end

        # One scheduled job per join, at fan-out time. Not a poller.
        def join_timeout(run_uuid, step_id, delay:, policy:)
          return if delay.nil?

          Agentkit::FlowJoinTimeoutJob.set(wait: delay).perform_later(run_uuid, step_id, policy.to_s)
        end
      end

      # Deterministic queue for specs.
      class TestQueue < Base
        Job = Struct.new(:kind, :args, :delay, keyword_init: true)

        def initialize
          @jobs = []
        end

        attr_reader :jobs

        def advance(run_uuid)         = enqueue(:advance, [run_uuid])
        def branch(run_uuid, step_id) = enqueue(:branch, [run_uuid, step_id])

        def join_timeout(run_uuid, step_id, delay:, policy:)
          enqueue(:join_timeout, [run_uuid, step_id, policy.to_s], delay)
        end

        def enqueue(kind, args, delay = nil)
          @jobs << Job.new(kind: kind, args: args, delay: delay)
        end

        def size    = @jobs.count { |j| j.kind != :join_timeout }
        def pending = @jobs.dup
        def clear   = @jobs = []

        # Run everything until the queue is empty. `order:` lets a spec prove
        # the barrier does not depend on branches finishing in order, and
        # `duplicate:` replays every job twice to prove idempotency.
        # @param limit [Integer, nil] stop after this many jobs — lets a spec
        #   freeze a run mid-fan-out and inspect the barrier.
        # @param max [Integer] runaway guard, not a target.
        def drain(order: :fifo, duplicate: false, limit: nil, max: 500)
          executed = 0
          while (job = take(order))
            run(job)
            run(job) if duplicate
            executed += 1
            break if limit && executed >= limit
            raise FlowError, "drain exceeded #{max} jobs (loop?)" if executed > max
          end
          executed
        end

        def fire_timeouts!
          timeouts = @jobs.select { |j| j.kind == :join_timeout }
          @jobs -= timeouts
          timeouts.each { |j| run(j) }
          timeouts.size
        end

        def run(job)
          case job.kind
          when :advance      then Worker.advance(*job.args)
          when :branch       then Worker.run_branch(*job.args)
          when :join_timeout then Worker.join_timeout(*job.args)
          end
        end

        private

        def take(order)
          return nil if @jobs.empty?

          runnable = @jobs.reject { |j| j.kind == :join_timeout }
          return nil if runnable.empty?

          job = case order
                when :lifo   then runnable.last
                when :random then runnable.sample
                else              runnable.first
                end
          @jobs.delete_at(@jobs.index(job))
          job
        end
      end
    end
  end
end
