# frozen_string_literal: true

module Agentkit
  # Immutable audit trail and XAI traces.
  #
  # Separate from Telemetry on purpose. They answer different questions and have
  # opposite requirements:
  #
  #   Telemetry  — "how is the system behaving?"  Sampled, aggregated, expires.
  #   Audit      — "what exactly did this agent do, and why?"  Complete,
  #                append-only, never sampled, retained as long as the domain
  #                requires (legal, health and finance customers need to prove
  #                which advice came from a verified fact and which from a
  #                hypothesis).
  #
  # v0.1 had `agentkit_agent_logs` with the full payload plus a 500-character
  # prompt preview. Routing that through Telemetry (as an earlier v2 draft did)
  # silently dropped every non-numeric field and made the record expire — a
  # regression, not a simplification.
  module Audit
    # One immutable record of something an agent did.
    Entry = Struct.new(
      :id, :event_type, :agent_name, :status, :prompt_preview, :model,
      :input_tokens, :output_tokens, :cost_usd, :duration_ms,
      :payload, :trace_id, :run_id, :step_key,
      :user_id, :account_id, :tenant_key, :subject_type, :subject_id,
      :occurred_at,
      keyword_init: true
    ) do
      def to_h = super.compact
    end

    # A multi-phase reasoning run: dreaming, summarizing, imagining, a council.
    # Shared infrastructure — one trace format for every cognitive process
    # instead of one per feature.
    class Trace
      attr_reader :id, :kind, :trigger, :phases, :started_at, :finished_at,
                  :status, :meta, :run_id, :tenant_key

      def initialize(kind:, trigger: :on_demand, meta: {}, run_id: nil)
        ctx          = Context.current
        @id          = SecureRandom.uuid
        @kind        = kind.to_s
        @trigger     = trigger.to_s
        @phases      = []
        @meta        = meta || {}
        @started_at  = Time.now
        @status      = "running"
        @run_id      = run_id || ctx&.run_id
        @tenant_key  = ctx&.tenant_key
      end

      # Every phase keeps its inputs and its scores, which is what makes the
      # result explainable after the fact instead of just observable.
      def phase(name, **data)
        entry = { name: name.to_s, at: Time.now, **data }
        @phases << entry
        entry
      end

      def complete!(status: "completed", **data)
        @status      = status.to_s
        @finished_at = Time.now
        @meta        = @meta.merge(data)

        Telemetry.emit("cognition.run",
                       dims: { processor: kind, trigger: trigger, status: @status },
                       measures: { phases: phases.size, duration_ms: duration_ms }
                                 .merge(data.select { |_, v| v.is_a?(Numeric) }))
        Audit.persist_trace(self)
        self
      end

      def skip!(reason) = complete!(status: "skipped", reason: reason)

      def duration_ms
        return 0 if @finished_at.nil?

        ((@finished_at - @started_at) * 1000).round
      end

      def to_h
        { id: id, kind: kind, trigger: trigger, status: status, run_id: run_id,
          tenant_key: tenant_key, started_at: started_at, finished_at: finished_at,
          duration_ms: duration_ms, phases: phases, meta: meta }
      end
    end

    class << self
      def store
        @store ||= build_store
      end

      attr_writer :store

      def reset!
        @store = nil
        @traces = nil
        self
      end

      # ─── Write ───────────────────────────────────────────────────────────────

      # Never raises: an audit failure must not take down the action it records.
      def record(event_type:, agent_name: nil, status: nil, payload: {}, prompt: nil,
                 model: nil, usage: nil, trace_id: nil, step_key: nil, subject: nil,
                 context: nil)
        return nil unless enabled?

        ctx = context || Context.current
        entry = Entry.new(
          event_type:    event_type.to_s,
          agent_name:    agent_name,
          status:        status&.to_s,
          prompt_preview: preview(prompt),
          model:         model || usage&.model,
          input_tokens:  usage&.input_tokens,
          output_tokens: usage&.output_tokens,
          cost_usd:      usage&.cost_usd,
          duration_ms:   usage&.duration_ms,
          # The full payload, not just the numeric keys.
          payload:       sanitize(payload),
          trace_id:      trace_id || ctx&.trace_id,
          run_id:        ctx&.run_id,
          step_key:      step_key,
          user_id:       id_of(ctx&.user),
          account_id:    id_of(ctx&.account),
          tenant_key:    ctx&.tenant_key || "__global__",
          subject_type:  subject&.class&.name,
          subject_id:    id_of(subject),
          occurred_at:   Time.now
        )
        store.append(entry)
        entry
      rescue StandardError => e
        Agentkit.logger&.warn("[AgentKit::Audit] record failed: #{e.message}")
        nil
      end

      def persist_trace(trace)
        return nil unless enabled?

        store.append_trace(trace)
        traces << trace
        traces.shift while traces.size > 500   # in-process convenience cache
        trace
      rescue StandardError => e
        Agentkit.logger&.warn("[AgentKit::Audit] trace failed: #{e.message}")
        nil
      end

      # ─── Read ────────────────────────────────────────────────────────────────

      def entries(agent: nil, event_type: nil, since: nil, trace_id: nil, run_id: nil, scope: nil)
        resolved = Scope.resolve(scope)
        store.entries(agent: agent, event_type: event_type, since: since,
                      trace_id: trace_id, run_id: run_id, scope: resolved)
      end

      def traces = @traces ||= []

      def find_trace(id, scope: nil)
        resolved = Scope.resolve(scope)
        store.find_trace(id, scope: resolved) || traces.find { |t| t.id == id && resolved.match?(t) }
      end

      def traces_for(kind: nil, since: nil, scope: nil)
        store.traces(kind: kind, since: since, scope: Scope.resolve(scope))
      end

      # Everything that happened under one correlation id: agent actions, the
      # cognitive traces they spawned, and the flow steps they ran in.
      def timeline(trace_id, scope: nil)
        resolved = Scope.resolve(scope)
        {
          trace_id: trace_id,
          entries:  entries(trace_id: trace_id, scope: resolved).sort_by(&:occurred_at),
          traces:   traces_for(scope: resolved).select { |t| t.id == trace_id || t.run_id == trace_id }
        }
      end

      # Why does this memory exist? Walks derived_from and the trace that made it.
      def provenance(memory, scope: nil)
        resolved = Scope.resolve(scope)
        return nil unless resolved.match?(memory)

        {
          memory_id:   memory.id,
          ontological: memory.ontological_type,
          source_agent: memory.source_agent,
          run_id:      memory.run_id,
          derived_from: memory.derived_from_memory_id,
          superseded_by: memory.superseded_by_id,
          trace:       (memory.metadata || {})["trace_id"]&.then { |id| find_trace(id, scope: resolved)&.to_h },
          sources:     (memory.metadata || {})["source_memory_ids"]
        }.compact
      end

      private

      def enabled? = Agentkit.config.audit.enabled

      # Prompt previews can carry personal data. Length is configurable and the
      # redaction list is applied before storage — set chars to 0 to disable.
      def preview(prompt)
        chars = Agentkit.config.audit.prompt_preview_chars.to_i
        return nil if prompt.nil? || chars.zero?

        redact(prompt.to_s)[0, chars]
      end

      def redact(text)
        Array(Agentkit.config.audit.redact).reduce(text) do |acc, pattern|
          acc.gsub(pattern, "[REDACTED]")
        end
      end

      def sanitize(payload)
        return {} if payload.nil?
        return { "value" => payload.to_s } unless payload.is_a?(Hash)

        payload.each_with_object({}) do |(k, v), acc|
          acc[k.to_s] = v.is_a?(String) ? redact(v) : v
        end
      end

      def id_of(obj) = obj.respond_to?(:id) ? obj.id : nil

      def build_store
        Agentkit.config.audit.store.to_sym == :active_record && defined?(Agentkit::AuditRecord) ?
          ActiveRecordStore.new : InMemory.new
      end
    end

    # ─── Stores ────────────────────────────────────────────────────────────────

    class InMemory
      LIMIT = 20_000

      def initialize
        @entries = []
        @traces  = []
        @mutex   = Mutex.new
        @seq     = 0
      end

      def append(entry)
        @mutex.synchronize do
          entry.id = (@seq += 1)
          @entries << entry
          @entries.shift(@entries.size - LIMIT) if @entries.size > LIMIT
        end
        entry
      end

      def append_trace(trace)
        @mutex.synchronize { @traces << trace }
        trace
      end

      def entries(agent: nil, event_type: nil, since: nil, trace_id: nil, run_id: nil, scope: nil)
        resolved = Scope.resolve(scope)
        @entries.select do |e|
          resolved.match?(e) && (agent.nil? || e.agent_name == agent.to_s) &&
            (event_type.nil? || e.event_type == event_type.to_s) &&
            (since.nil?      || e.occurred_at >= since) &&
            (trace_id.nil?   || e.trace_id == trace_id) &&
            (run_id.nil?     || e.run_id == run_id)
        end
      end

      def traces(kind: nil, since: nil, scope: nil)
        resolved = Scope.resolve(scope)
        @traces.select do |t|
          resolved.match?(t) && (kind.nil? || t.kind == kind.to_s) &&
            (since.nil? || t.started_at >= since)
        end
      end

      def find_trace(id, scope: nil)
        resolved = Scope.resolve(scope)
        @traces.find { |t| t.id == id && resolved.match?(t) }
      end

      def clear
        @mutex.synchronize { @entries = []; @traces = []; @seq = 0 }
      end

      def size = @entries.size
    end

    # Append-only by contract: no update, no delete. Retention is a separate,
    # explicit operation (`Agentkit::Audit::ActiveRecordStore#prune!`).
    class ActiveRecordStore
      def append(entry)
        row = Agentkit::AuditRecord.create!(entry.to_h.except(:id))
        entry.id = row.id
        entry
      end

      def append_trace(trace)
        row = Agentkit::TraceRecord.create!(
          trace_id: trace.id, kind: trace.kind, trigger: trace.trigger,
          status: trace.status, run_id: trace.run_id, tenant_key: trace.tenant_key || "__global__",
          meta: trace.meta, started_at: trace.started_at,
          finished_at: trace.finished_at, duration_ms: trace.duration_ms
        )
        trace.phases.each_with_index do |phase, i|
          Agentkit::TracePhaseRecord.create!(
            trace_id: row.id, position: i, name: phase[:name],
            occurred_at: phase[:at], data: phase.except(:name, :at), tenant_key: row.tenant_key
          )
        end
        trace
      end

      def entries(agent: nil, event_type: nil, since: nil, trace_id: nil, run_id: nil, scope: nil)
        relation = audit_relation(scope)
        relation = relation.where(agent_name: agent.to_s) if agent
        relation = relation.where(event_type: event_type.to_s) if event_type
        relation = relation.where(occurred_at: since..) if since
        relation = relation.where(trace_id: trace_id) if trace_id
        relation = relation.where(run_id: run_id) if run_id
        relation.order(:occurred_at).map { |r| wrap(r) }
      end

      def traces(kind: nil, since: nil, scope: nil)
        relation = trace_relation(scope)
        relation = relation.where(kind: kind.to_s) if kind
        relation = relation.where(started_at: since..) if since
        relation.order(started_at: :desc)
      end

      def find_trace(id, scope: nil) = trace_relation(scope).find_by(trace_id: id)

      # The only way an audit row ever disappears, and it is deliberate.
      def prune!(older_than:)
        Agentkit::AuditRecord.where(occurred_at: ...older_than).delete_all
      end

      private

      def audit_relation(scope)
        resolved = Scope.resolve(scope)
        relation = Agentkit::AuditRecord.all
        relation = relation.where(tenant_key: resolved.tenant_key) if resolved.tenant_key
        relation = relation.where(account_id: resolved.account_id) if resolved.account_id
        relation
      end

      def trace_relation(scope)
        resolved = Scope.resolve(scope)
        relation = Agentkit::TraceRecord.all
        relation = relation.where(tenant_key: resolved.tenant_key) if resolved.tenant_key
        relation
      end

      def wrap(row)
        Entry.new(**row.attributes.symbolize_keys.slice(*Entry.members))
      end
    end
  end
end
