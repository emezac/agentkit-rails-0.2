# frozen_string_literal: true

module Agentkit
  # Optional, model-free routing of trusted source events to an existing
  # mandated Flow run. The host authenticates each source event and decides
  # when to feed pending data to its worker; event payloads grant no authority.
  module TaskEvents
    MAX_PAYLOAD_BYTES = 4_096
    module_function

    def subscribe!(run_id:, context:)
      run = scoped_run!(run_id, context)
      raise FlowError, "finished task cannot subscribe" if %w[completed failed compensated cancelled timed_out].include?(run.status)
      mandate = TaskMandate.mandate_data(run) || raise(PolicyDenied, "run has no mandate")
      TaskMandate.guard_run!(run, phase: "subscribe")
      identity = { tenant_key: run.tenant_key, account_key: account_key(run.account_id), account_id: run.account_id,
                   source: mandate.fetch("source"), resource: mandate.fetch("resource"),
                   thread: mandate.fetch("thread") }
      row = TaskThreadRecord.create_or_find_by!(identity) { |record| record.run_id = run.run_id }
      raise IdempotencyConflict, "thread already belongs to another task" unless row.run_id == run.run_id
      row
    end

    def ingest!(source:, resource:, thread:, event_id:, payload:, context:, authorize:)
      raise ConfigurationError, "source authorization callback required" unless authorize.respond_to?(:call)
      raise PolicyDenied, "source event denied" unless authorize.call(source, resource, thread, event_id, context) == true
      [source, resource, thread, event_id].each { |field| identifier!(field) }
      scope = scope_for(context)
      subscription = TaskThreadRecord.find_by(tenant_key: scope.fetch(:tenant_key), account_key: account_key(scope[:account_id]),
        source: source.to_s, resource: resource.to_s, thread: thread.to_s)
      return nil unless subscription
      run = RunRecord.find_by(run_id: subscription.run_id, tenant_key: scope.fetch(:tenant_key), account_id: scope[:account_id])
      return nil unless run && !%w[completed failed compensated cancelled timed_out].include?(run.status)

      bounded = Harness::DeclarativeData.normalize(payload, label: "task event")
      raise ArgumentError, "task event must be a bounded object" unless bounded.is_a?(Hash) &&
        JSON.generate(bounded).bytesize.between?(1, MAX_PAYLOAD_BYTES)
      key = Digest::SHA256.hexdigest(event_id.to_s)
      digest = Harness.digest(bounded)
      row = subscription.events.create_or_find_by!(event_key: key) do |record|
        record.payload_digest = digest
        record.payload = bounded
      end
      raise IdempotencyConflict, "event identity reused with different payload" unless row.payload_digest == digest
      { run_id: subscription.run_id, event_key: key }
    end

    def pending(run_id:, context:, limit: 50)
      raise ArgumentError, "limit must be 1..100" unless limit.is_a?(Integer) && limit.between?(1, 100)
      run = scoped_run!(run_id, context)
      TaskMandate.guard_run!(run, phase: "read_events")
      thread = TaskThreadRecord.find_by(tenant_key: run.tenant_key, account_key: account_key(run.account_id), run_id: run.run_id)
      return [] unless thread
      thread.events.where(consumed_at: nil).order(:id).limit(limit).map do |row|
        { event_key: row.event_key, payload: row.payload, received_at: row.created_at }
      end
    end

    def mark_consumed!(run_id:, event_key:, context:)
      run = scoped_run!(run_id, context)
      TaskMandate.guard_run!(run, phase: "consume_event")
      thread = TaskThreadRecord.find_by!(tenant_key: run.tenant_key, account_key: account_key(run.account_id), run_id: run.run_id)
      row = thread.events.find_by!(event_key: event_key)
      row.update!(consumed_at: Time.now.utc) unless row.consumed_at
      true
    end

    def metrics(run_id:, context:)
      run = scoped_run!(run_id, context)
      TaskMandate.guard_run!(run, phase: "read_metrics")
      thread = TaskThreadRecord.find_by(tenant_key: run.tenant_key, account_key: account_key(run.account_id), run_id: run.run_id)
      { status: run.status, cost_usd: run.cost_usd.to_s,
        elapsed_seconds: run.started_at && run.finished_at ? (run.finished_at - run.started_at).round(3) : nil,
        human_gate_resolutions: RunStepRecord.where(run_id: run.id, kind: "human_gate", status: "completed").count,
        events_received: thread ? thread.events.count : 0,
        events_pending: thread ? thread.events.where(consumed_at: nil).count : 0 }
    end

    # The host schedules retention. Pending events remain available until the
    # host explicitly marks them consumed or resolves the task.
    def prune_consumed!(before:, context:, authorize:, limit: 1_000)
      raise ConfigurationError, "retention authorization callback required" unless authorize.respond_to?(:call)
      raise PolicyDenied, "retention denied" unless authorize.call("prune_consumed", context) == true
      raise ArgumentError, "before must be a Time" unless before.is_a?(Time)
      raise ArgumentError, "limit must be 1..1000" unless limit.is_a?(Integer) && limit.between?(1, 1_000)
      scope = scope_for(context)
      ids = TaskEventRecord.joins(:task_thread)
        .where(agentkit_task_threads: { tenant_key: scope.fetch(:tenant_key), account_key: account_key(scope[:account_id]) })
        .where(redacted_at: nil).where("agentkit_task_events.consumed_at < ?", before)
        .order(:id).limit(limit).pluck(:id)
      TaskEventRecord.where(id: ids).update_all(payload: {}, redacted_at: Time.now.utc)
    end

    def scoped_run!(run_id, context)
      scope = scope_for(context)
      RunRecord.find_by!(run_id: run_id, tenant_key: scope.fetch(:tenant_key), account_id: scope[:account_id])
    end

    def scope_for(context)
      scope = Scope.resolve(context: context)
      raise ConfigurationError, "task events require a tenant and principal" if scope.tenant_key.to_s.empty? || context.principal.to_s.empty?
      { tenant_key: scope.tenant_key, account_id: scope.account_id }
    end

    def account_key(value) = value.nil? ? "__none__" : value.to_s
    def identifier!(value)
      text = value.to_s
      raise ArgumentError, "source identity must contain 1..256 safe bytes" unless
        text.bytesize.between?(1, 256) && !text.match?(/[[:cntrl:]]/)
      text
    end
  end
end
