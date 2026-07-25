# frozen_string_literal: true

module Agentkit
  class Flow
    # Persisted state of one execution. Steps are the resumable unit: if the
    # process dies between two steps, the run continues from the next pending
    # one instead of starting over.
    class Run
      STATUSES = %w[pending running waiting_join waiting_human completed failed
                    compensating compensated cancelled timed_out].freeze

      attr_accessor :id, :flow_name, :flow_version, :run_id, :status, :input, :output,
                    :context, :idempotency_key, :account_id, :user_id, :tenant_key,
                    :started_at, :finished_at, :deadline_at, :error, :cost_usd,
                    :steps_total, :steps_completed

      def initialize(**attrs)
        attrs.each { |k, v| instance_variable_set(:"@#{k}", v) }
        @status         ||= "pending"
        @run_id         ||= SecureRandom.uuid
        @input          ||= {}
        @output         ||= {}
        @cost_usd       ||= 0.0
        @steps_total    ||= 0
        @steps_completed ||= 0
        @steps          = []
      end

      attr_reader :steps

      def add_step(step)
        @steps << step
        step
      end

      def step(name)     = @steps.find { |s| s.step_name.to_s == name.to_s }
      def steps_named(name) = @steps.select { |s| s.step_name.to_s == name.to_s }
      def children_of(parent_id) = @steps.select { |s| s.parent_step_id == parent_id }

      def running?   = status == "running"
      def finished?  = %w[completed failed compensated cancelled timed_out].include?(status)
      def waiting?   = %w[waiting_join waiting_human].include?(status)
      def ok?        = status == "completed"

      def cancel! = @status = "cancelled"

      def timed_out?(now = Time.now) = !deadline_at.nil? && deadline_at < now

      def to_h
        { id: id, run_id: run_id, flow: flow_name, version: flow_version, status: status,
          steps: @steps.size, completed: steps_completed, cost_usd: cost_usd.round(6),
          started_at: started_at, finished_at: finished_at, error: error }
      end
    end

    # One executed node. `step_key` is unique per run — that uniqueness is what
    # makes a redelivered job a no-op instead of a double execution.
    class RunStep
      STATUSES = %w[pending running completed failed skipped timed_out cancelled].freeze

      attr_accessor :id, :run_id, :step_key, :step_name, :kind, :status, :position,
                    :parent_step_id, :pending_count, :input, :output, :attempts,
                    :attempt_count, :usage, :started_at, :finished_at, :timeout_at,
                    :error, :iteration

      def initialize(**attrs)
        attrs.each { |k, v| instance_variable_set(:"@#{k}", v) }
        @status        ||= "pending"
        @attempts      ||= []
        @attempt_count ||= 0
        @input         ||= {}
        @output        ||= {}
      end

      def completed? = status == "completed"
      def failed?    = status == "failed"
      def settled?   = %w[completed failed skipped timed_out cancelled].include?(status)

      # Decoded value of the step. `output` holds the wire format (see
      # Flow::Coder); nobody outside the executor should have to know that.
      def result(store = nil)
        raw = raw_result
        return nil if raw.nil?

        decoded = Flow::Coder.load(raw, store: store)
        decoded.is_a?(Result) ? decoded.value : decoded
      end

      def raw_result
        return nil if output.nil? || output.empty?

        output["result"] || output[:result]
      end

      def record_attempt(error: nil, duration_ms: nil)
        @attempt_count += 1
        @attempts << { n: @attempt_count, at: Time.now, error: error&.message,
                       error_class: error&.class&.name, duration_ms: duration_ms }
      end

      def to_h
        { key: step_key, name: step_name, kind: kind, status: status,
          attempts: attempt_count, duration_ms: duration_ms, error: error }
      end

      def duration_ms
        return nil unless started_at && finished_at

        ((finished_at - started_at) * 1000).round
      end
    end

    # Run persistence port.
    module Store
      def self.build(name)
        case name.to_sym
        when :memory        then InMemory.new
        when :active_record then ActiveRecordStore.new
        else raise ConfigurationError, "Unknown flow store: #{name}"
        end
      end

      class InMemory
        def initialize
          @runs  = {}
          @seq   = 0
          @steps = 0
          @mutex = Mutex.new
        end

        def create_run(run)
          @mutex.synchronize { run.id ||= (@seq += 1) }
          @runs[run.id] = run
        end

        def find_run(id)          = @runs[id]

        def find_step(run, id)
          return nil if id.nil?

          run.steps.find { |s| s.id == id }
        end

        # Oversized step outputs live outside the row (see Flow::Coder).
        def put_artifact(payload)
          @artifacts ||= {}
          id = (@artifact_seq = (@artifact_seq || 0) + 1)
          @artifacts[id] = payload
          id
        end

        def get_artifact(id) = (@artifacts || {})[id]
        def find_run_by_uuid(uuid) = @runs.values.find { |r| r.run_id == uuid }
        def update_run(run, **attrs)
          attrs.each { |k, v| run.public_send(:"#{k}=", v) }
          run
        end

        def find_by_idempotency(key)
          return nil if key.nil?

          @runs.values.find { |r| r.idempotency_key == key && !%w[failed cancelled].include?(r.status) }
        end

        # Returns [step, created?]. The uniqueness of (run_id, step_key) is
        # enforced here in-process and by a unique index in SQL — it is the
        # idempotency guarantee the whole engine rests on.
        def find_or_create_step(run, step_key:, **attrs)
          existing = run.steps.find { |s| s.step_key == step_key }
          return [existing, false] if existing

          step = RunStep.new(step_key: step_key, run_id: run.id, id: @mutex.synchronize { @steps += 1 }, **attrs)
          run.add_step(step)
          [step, true]
        end

        def update_step(step, **attrs)
          attrs.each { |k, v| step.public_send(:"#{k}=", v) }
          step
        end

        # Atomic close + barrier decrement. The child that brings the counter to
        # zero is the one that fires the continuation — "last one turns off the
        # lights". A redelivered job finds status already `completed` and does
        # not decrement twice.
        def close_and_decrement(step, join_step, status:, output: nil)
          @mutex.synchronize do
            return nil if step.status == "completed"

            step.status      = status
            step.output      = output if output
            step.finished_at = Time.now
            next nil if join_step.nil?

            join_step.pending_count = join_step.pending_count.to_i - 1
          end
        end

        def runs(status: nil)
          @runs.values.select { |r| status.nil? || r.status == status.to_s }
        end

        def all_steps = @runs.values.flat_map(&:steps)

        def clear
          @mutex.synchronize { @runs = {}; @seq = 0; @steps = 0 }
        end
      end

      # Delegates to the engine's ActiveRecord models. The barrier is a single
      # UPDATE ... RETURNING, which is why no distributed lock is needed.
      class ActiveRecordStore
        def create_run(run)
          row = Agentkit::RunRecord.create!(run_attributes(run))
          run.id = row.id
          run
        end

        def find_run(id)           = wrap(Agentkit::RunRecord.find_by(id: id))
        def find_run_by_uuid(uuid) = wrap(Agentkit::RunRecord.find_by(run_id: uuid))

        def find_step(run, id)
          return nil if id.nil?

          run.steps.find { |s| s.id == id } || register(run, wrap_step(Agentkit::RunStepRecord.find_by(id: id)))
        end

        def put_artifact(payload)
          Agentkit::ArtifactRecord.create!(kind: "flow_payload", content_type: "application/json",
                                           body: JSON.generate(payload),
                                           content_hash: Digest::SHA256.hexdigest(JSON.generate(payload))[0, 32],
                                           tenant_key: Context.current&.tenant_key).id
        end

        def get_artifact(id)
          row = Agentkit::ArtifactRecord.find_by(id: id)
          row && JSON.parse(row.body)
        end

        def update_run(run, **attrs)
          attrs.each { |k, v| run.public_send(:"#{k}=", v) }
          Agentkit::RunRecord.where(id: run.id).update_all(attrs.merge(updated_at: Time.now))
          run
        end

        def find_by_idempotency(key)
          return nil if key.nil?

          wrap(Agentkit::RunRecord.where(idempotency_key: key).where.not(status: %w[failed cancelled]).first)
        end

        # The in-memory Run has to know its own steps: `steps_named`,
        # `children_of` and the fan-out replay all read from it. Forgetting to
        # register them here left run.steps empty under ActiveRecord while the
        # in-memory store worked fine.
        def find_or_create_step(run, step_key:, **attrs)
          existing = run.steps.find { |s| s.step_key == step_key }
          return [existing, false] if existing

          row = Agentkit::RunStepRecord.create_with(attrs.merge(run_id: run.id))
                                       .find_or_create_by(run_id: run.id, step_key: step_key)
          [register(run, wrap_step(row)), row.previously_new_record?]
        rescue ActiveRecord::RecordNotUnique
          row = Agentkit::RunStepRecord.find_by(run_id: run.id, step_key: step_key)
          [register(run, wrap_step(row)), false]
        end

        def update_step(step, **attrs)
          attrs.each { |k, v| step.public_send(:"#{k}=", v) }
          Agentkit::RunStepRecord.where(id: step.id).update_all(attrs.merge(updated_at: Time.now))
          step
        end

        def close_and_decrement(step, join_step, status:, output: nil)
          closed = Agentkit::RunStepRecord
                   .where(id: step.id).where.not(status: "completed")
                   .update_all(status: status, output: output || {}, finished_at: Time.now)
          return nil if closed.zero?   # redelivery: someone already closed it
          return nil if join_step.nil?

          Agentkit::RunStepRecord.connection.select_value(
            Agentkit::RunStepRecord.sanitize_sql_array(
              ["UPDATE agentkit_run_steps SET pending_count = pending_count - 1 " \
               "WHERE id = ? RETURNING pending_count", join_step.id]
            )
          ).to_i
        end

        private

        def register(run, step)
          return nil if step.nil?
          return step if run.steps.any? { |s| s.id == step.id }

          run.add_step(step)
          step
        end

        def run_attributes(run)
          { flow_name: run.flow_name, flow_version: run.flow_version, run_id: run.run_id,
            status: run.status, input: run.input, context: run.context,
            idempotency_key: run.idempotency_key, account_id: run.account_id,
            user_id: run.user_id, tenant_key: run.tenant_key, deadline_at: run.deadline_at,
            started_at: run.started_at }
        end

        def wrap(row)
          return nil if row.nil?

          run = Run.new(id: row.id, flow_name: row.flow_name, flow_version: row.flow_version,
                        run_id: row.run_id, status: row.status, input: row.input,
                        output: row.output, context: row.context,
                        idempotency_key: row.idempotency_key, tenant_key: row.tenant_key,
                        deadline_at: row.deadline_at, started_at: row.started_at,
                        finished_at: row.finished_at, cost_usd: row.cost_usd)
          row.steps.each { |s| run.add_step(wrap_step(s)) }
          run
        end

        def wrap_step(row)
          return nil if row.nil?

          RunStep.new(id: row.id, run_id: row.run_id, step_key: row.step_key,
                      step_name: row.step_name, kind: row.kind, status: row.status,
                      position: row.position, parent_step_id: row.parent_step_id,
                      pending_count: row.pending_count, input: row.input, output: row.output,
                      attempts: row.attempts, attempt_count: row.attempt_count,
                      usage: row.usage, started_at: row.started_at, finished_at: row.finished_at)
        end
      end
    end
  end
end
