# frozen_string_literal: true

require_relative "telemetry/stats"
require_relative "telemetry/backends"

module Agentkit
  # Event bus wired into the kernel's own seams. The point of putting this in
  # F1 rather than at the end: v0.1's Fábrica shipped with nowhere to read from,
  # so the only signal it had was a count of exceptions.
  #
  # Domain code emits nothing to get the first 90% of the signal — every LLM
  # call, memory write/recall, HITL decision, flow step and proposal is probed
  # by the kernel itself.
  #
  # Writes are buffered and flushed in batches. v0.1 wrote one synchronous
  # INSERT per `chat`, which is exactly why `tres` overrode `agent_log` to a
  # no-op and lost its telemetry entirely.
  module Telemetry
    Event = Struct.new(:name, :dims, :measures, :occurred_at, :run_id, :trace_id, keyword_init: true) do
      def to_h
        { name: name, dims: dims, measures: measures,
          occurred_at: occurred_at, run_id: run_id, trace_id: trace_id }
      end
    end

    class << self
      # ─── Emission ──────────────────────────────────────────────────────────

      def emit(name, dims: {}, measures: {})
        return unless enabled?
        return unless sampled?(name)

        ctx   = Context.current
        event = Event.new(
          name:        name.to_s,
          dims:        normalize(dims).merge(ctx ? ctx.telemetry_dims : {}),
          measures:    normalize_measures(measures),
          occurred_at: Time.now,
          run_id:      ctx&.run_id,
          trace_id:    ctx&.trace_id
        )

        subscribers.each { |s| safely { s.call(event) } }
        buffer << event
        flush! if buffer.size >= Agentkit.config.telemetry.flush_size
        event
      end

      # Time a block and emit duration_ms plus whatever the block returns as
      # extra measures via the yielded hash.
      #
      #   Telemetry.measure("llm.call", dims: { model: }) do |m|
      #     resp = provider.call
      #     m[:tokens] = resp.tokens
      #     resp
      #   end
      def measure(name, dims: {}, measures: {})
        extra   = {}
        started = monotonic
        status  = "ok"
        begin
          result = yield(extra)
        rescue StandardError => e
          status = "error"
          extra[:error_class] = e.class.name
          raise
        ensure
          emit(name,
               dims:     dims.merge(status: status),
               measures: measures.merge(extra).merge(duration_ms: ((monotonic - started) * 1000).round))
        end
        result
      end

      # ─── Buffer / backends ─────────────────────────────────────────────────

      def buffer
        @buffer ||= []
      end

      def flush!
        return [] if buffer.empty?

        batch = buffer.dup
        @buffer = []
        backends.each { |b| safely { b.write(batch) } }
        batch
      end

      def backends
        @backends ||= Array(Agentkit.config.telemetry.backends).map { |b| Backends.build(b) }
      end

      attr_writer :backends

      # In-process listeners (the factory's live detectors, test assertions).
      def subscribe(&block)
        subscribers << block
        block
      end

      def unsubscribe(handle)
        subscribers.delete(handle)
      end

      def subscribers
        @subscribers ||= []
      end

      # ─── Query (delegates to the backend that can answer) ──────────────────

      def events(name: nil, since: nil, dims: {})
        flush!
        backends.filter_map { |b| b.events(name: name, since: since, dims: dims) if b.respond_to?(:events) }
                .flatten
      end

      # Descriptive statistics for a probe point, grouped by dimensions.
      #
      #   Telemetry.stats("llm.call", measure: :duration_ms, by: :model)
      #   # => { "claude-opus-4-6" => #<Stats n=42 p50=980.0 p95=2310.0 ...> }
      def stats(name, measure: :duration_ms, by: nil, since: nil)
        rows = events(name: name, since: since)
        values_for = ->(list) { list.filter_map { |e| e.measures[measure.to_sym] }.map(&:to_f) }

        return Stats.from(values_for.call(rows)) if by.nil?

        rows.group_by { |e| e.dims[by.to_sym] }
            .transform_values { |list| Stats.from(values_for.call(list)) }
      end

      # Rate of a boolean-ish measure (e.g. cache_hit) over a probe point.
      def rate(name, measure:, since: nil)
        rows = events(name: name, since: since)
        return 0.0 if rows.empty?

        hits = rows.count { |e| truthy?(e.measures[measure.to_sym]) }
        (hits.to_f / rows.size).round(4)
      end

      def reset!
        @buffer      = []
        @backends    = nil
        @subscribers = []
        Backends.reset!
        self
      end

      private

      def enabled?
        Agentkit.config.telemetry.enabled
      end

      def sampled?(name)
        rate = Agentkit.config.telemetry.sampling[name.to_s] ||
               Agentkit.config.telemetry.sampling[name.to_sym]
        return true if rate.nil? || rate >= 1.0

        Kernel.rand < rate
      end

      def normalize(dims)
        (dims || {}).each_with_object({}) do |(k, v), acc|
          next if v.nil?

          acc[k.to_sym] = v.is_a?(Symbol) || v.is_a?(Numeric) || v == true || v == false ? v : v.to_s
        end
      end

      def normalize_measures(measures)
        (measures || {}).each_with_object({}) do |(k, v), acc|
          acc[k.to_sym] = v
        end
      end

      def truthy?(value)
        value == true || value == 1 || value == "true"
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def safely
        yield
      rescue StandardError => e
        # Telemetry must never break the thing it is measuring.
        Agentkit.logger&.warn("[AgentKit::Telemetry] #{e.class}: #{e.message}")
      end
    end
  end
end
