# frozen_string_literal: true

require "openssl"
require "time"

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
      :occurred_at, :schema_version, :sequence, :principal_id,
      :payload_digest, :previous_hash, :event_hash, :signature, :key_id,
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

      # Best-effort remains appropriate for ordinary diagnostics. Sensitive
      # operations can pass failure_mode: :required (or configure it globally)
      # so the action fails closed when its evidence cannot be persisted.
      def record(event_type:, agent_name: nil, status: nil, payload: {}, prompt: nil,
                 model: nil, usage: nil, trace_id: nil, step_key: nil, subject: nil,
                 context: nil, failure_mode: nil)
        return nil unless enabled? || required_failure_mode?(failure_mode)
        unless enabled?
          handle_write_failure(ConfigurationError.new("audit is disabled"),
                               operation: :record, failure_mode: failure_mode)
        end

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
          occurred_at:   Time.now,
          schema_version: Agentkit.config.audit.schema_version,
          principal_id: principal_id(ctx)
        )
        store.append(entry)
        entry
      rescue AuditPersistenceError
        raise
      rescue StandardError => e
        handle_write_failure(e, operation: :record, failure_mode: failure_mode)
      end

      def persist_trace(trace, failure_mode: nil)
        return nil unless enabled? || required_failure_mode?(failure_mode)
        unless enabled?
          handle_write_failure(ConfigurationError.new("audit is disabled"),
                               operation: :trace, failure_mode: failure_mode)
        end

        store.append_trace(trace)
        traces << trace
        traces.shift while traces.size > 500   # in-process convenience cache
        trace
      rescue AuditPersistenceError
        raise
      rescue StandardError => e
        handle_write_failure(e, operation: :trace, failure_mode: failure_mode)
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

      # Shared presentation boundary for administrative surfaces. It applies
      # the same recursive policy used before durable audit writes.
      def sanitize_payload(payload)
        sanitize(payload)
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

      # Verifies the complete v2 chain for one tenant, including sequence,
      # payload digest, event hash and HMAC signature. Legacy v1 rows remain
      # readable but are intentionally outside the cryptographic chain.
      def verify!(tenant_key: "__global__")
        rows = store.entries(scope: { tenant_key: tenant_key })
                    .select { |entry| entry.schema_version.to_i == 2 }
                    .sort_by { |entry| entry.sequence.to_i }
        previous = nil
        rows.each_with_index do |entry, index|
          expected_sequence = index + 1
          raise AuditIntegrityError, "audit sequence gap at #{entry.id}" unless entry.sequence.to_i == expected_sequence
          raise AuditIntegrityError, "audit previous hash mismatch at #{entry.id}" unless entry.previous_hash == previous
          expected_payload = canonical_digest(entry.payload || {})
          raise AuditIntegrityError, "audit payload digest mismatch at #{entry.id}" unless secure_equal?(entry.payload_digest, expected_payload)
          expected_hash = event_hash(entry)
          raise AuditIntegrityError, "audit event hash mismatch at #{entry.id}" unless secure_equal?(entry.event_hash, expected_hash)
          key = signing_key(entry.key_id, store: store)
          expected_signature = OpenSSL::HMAC.hexdigest("SHA256", key, entry.event_hash)
          raise AuditIntegrityError, "audit signature mismatch at #{entry.id}" unless secure_equal?(entry.signature, expected_signature)
          previous = entry.event_hash
        end
        { tenant_key: tenant_key, entries: rows.size, last_hash: previous, valid: true }
      end

      def seal!(entry, sequence:, previous_hash:, store:)
        entry.sequence = sequence
        entry.previous_hash = previous_hash
        entry.payload_digest = canonical_digest(entry.payload || {})
        entry.key_id = Agentkit.config.audit.active_key_id
        entry.event_hash = event_hash(entry)
        entry.signature = OpenSSL::HMAC.hexdigest("SHA256", signing_key(entry.key_id, store: store), entry.event_hash)
        entry
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

      def principal_id(context)
        value = context&.principal || context&.user
        value.respond_to?(:id) ? value.id.to_s : value&.to_s
      end

      def canonical_digest(value)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(value)))}"
      end

      def canonicalize(value)
        case value
        when Hash then value.map { |key, item| [key.to_s, canonicalize(item)] }.sort.to_h
        when Array then value.map { |item| canonicalize(item) }
        when Time then value.utc.iso8601(6)
        else value
        end
      end

      def event_hash(entry)
        fields = entry.to_h.reject { |key, _| %i[id event_hash signature].include?(key) }
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(fields)))}"
      end

      def signing_key(key_id, store:)
        key = Agentkit.config.audit.signing_keys[key_id] || Agentkit.config.audit.signing_keys[key_id.to_s]
        return key.to_s unless key.to_s.empty?
        return "agentkit-in-memory-audit-key" if store.is_a?(InMemory)

        raise ConfigurationError, "audit v2 signing key #{key_id.inspect} is not configured"
      end

      def secure_equal?(left, right)
        return false unless left && right && left.bytesize == right.bytesize

        accumulator = 0
        left.bytes.zip(right.bytes) { |a, b| accumulator |= a ^ b }
        accumulator.zero?
      end

      def enabled? = Agentkit.config.audit.enabled

      def required_failure_mode?(failure_mode)
        (failure_mode || Agentkit.config.audit.failure_mode).to_sym == :required
      end

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

      def sanitize(value, key: nil)
        return "[REDACTED]" if key && sensitive_key?(key)

        case value
        when nil then key.nil? ? {} : nil
        when Hash
          value.each_with_object({}) do |(nested_key, nested_value), acc|
            acc[nested_key.to_s] = sanitize(nested_value, key: nested_key)
          end
        when Array then value.map { |item| sanitize(item) }
        when String then redact(value)
        when Numeric, TrueClass, FalseClass then value
        else redact(value.to_s)
        end
      end

      def sensitive_key?(key)
        normalized = key.to_s.downcase.tr("-", "_")
        Array(Agentkit.config.audit.redact_keys).any? do |candidate|
          token = candidate.to_s.downcase.tr("-", "_")
          normalized == token || normalized.end_with?("_#{token}")
        end
      end

      def handle_write_failure(error, operation:, failure_mode: nil)
        mode = (failure_mode || Agentkit.config.audit.failure_mode).to_sym
        request_id = SecureRandom.uuid
        Telemetry.emit("audit.write_failed",
                       dims: { operation: operation.to_s, error_class: error.class.name,
                               failure_mode: mode.to_s, request_id: request_id },
                       measures: { count: 1 })
        Agentkit.logger&.warn(
          "[AgentKit::Audit] #{operation} failed request_id=#{request_id} error=#{error.class}"
        )
        if mode == :required
          raise AuditPersistenceError,
                "required audit persistence failed (request_id=#{request_id})"
        end

        nil
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
          if entry.schema_version.to_i == 2
            tenant = entry.tenant_key || "__global__"
            @heads ||= {}
            head = @heads[tenant] || { sequence: 0, hash: nil }
            Audit.seal!(entry, sequence: head[:sequence] + 1,
                        previous_hash: head[:hash], store: self)
            @heads[tenant] = { sequence: entry.sequence, hash: entry.event_hash }
          end
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
        @mutex.synchronize { @entries = []; @traces = []; @heads = {}; @seq = 0 }
      end

      def size = @entries.size
    end

    # Append-only by contract: no update, no delete. Retention is a separate,
    # explicit operation (`Agentkit::Audit::ActiveRecordStore#prune!`).
    class ActiveRecordStore
      def append(entry)
        Agentkit::AuditRecord.transaction do
          if entry.schema_version.to_i == 2
            head = locked_head(entry.tenant_key)
            Audit.seal!(entry, sequence: head.sequence + 1,
                        previous_hash: head.last_hash, store: self)
            row = Agentkit::AuditRecord.create!(entry.to_h.except(:id))
            head.update!(sequence: entry.sequence, last_hash: entry.event_hash)
          else
            row = Agentkit::AuditRecord.create!(entry.to_h.except(:id))
          end
          entry.id = row.id
          entry
        end
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
        relation = Agentkit::AuditRecord.where(occurred_at: ...older_than)
        grouped = relation.group(:tenant_key).maximum(:event_hash)
        grouped.each do |tenant, hash|
          Audit.record(event_type: "audit.checkpoint", status: "created",
                       payload: { pruned_before: older_than.utc.iso8601, last_pruned_hash: hash },
                       context: Context.new(tenant_key: tenant,
                                            principal: "system:audit_retention"),
                       failure_mode: :required)
        end
        relation.delete_all
      end

      private

      def locked_head(tenant_key)
        tenant = tenant_key || "__global__"
        Agentkit::AuditChainHeadRecord.create_or_find_by!(tenant_key: tenant)
        Agentkit::AuditChainHeadRecord.lock.find_by!(tenant_key: tenant)
      end

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
