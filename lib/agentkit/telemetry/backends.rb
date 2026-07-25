# frozen_string_literal: true

module Agentkit
  module Telemetry
    # Output adapters. `:db` is the default because the factory and the
    # dashboard read from it; the others exist so a host with its own stack
    # doesn't have to double-store.
    module Backends
      class << self
        def build(name)
          case name.to_sym
          when :memory then MemoryBackend.instance
          when :db     then ActiveRecordBackend.new
          when :log    then LogBackend.new
          when :otel   then OtelBackend.new
          when :statsd then StatsdBackend.new
          else raise ConfigurationError, "Unknown telemetry backend: #{name}"
          end
        end

        def reset!
          MemoryBackend.instance.clear
        end
      end

      # In-process ring buffer. Default in tests and the only backend that can
      # answer queries without a database, which keeps the kernel unit-testable.
      class MemoryBackend
        LIMIT = 50_000

        def self.instance
          @instance ||= new
        end

        def initialize
          @events = []
          @mutex  = Mutex.new
        end

        def write(batch)
          @mutex.synchronize do
            @events.concat(batch)
            @events.shift(@events.size - LIMIT) if @events.size > LIMIT
          end
        end

        def events(name: nil, since: nil, dims: {})
          @mutex.synchronize { @events.dup }.select do |e|
            (name.nil?  || e.name == name.to_s) &&
              (since.nil? || e.occurred_at >= since) &&
              dims.all? { |k, v| e.dims[k.to_sym] == v }
          end
        end

        def clear
          @mutex.synchronize { @events = [] }
        end

        def size = @events.size
      end

      # Persists to agentkit_events. Falls back to a no-op when the engine is
      # not loaded, so the pure-Ruby core never blows up.
      class ActiveRecordBackend
        def available?
          defined?(Agentkit::EventRecord) && Agentkit::EventRecord.respond_to?(:insert_all)
        end

        def write(batch)
          return unless available?
          return if batch.empty?

          rows = batch.map do |e|
            { name: e.name, dims: e.dims, measures: e.measures, run_id: e.run_id,
              trace_id: e.trace_id, occurred_at: e.occurred_at,
              created_at: e.occurred_at, updated_at: e.occurred_at }
          end
          Agentkit::EventRecord.insert_all(rows)
        end

        def events(name: nil, since: nil, dims: {})
          return [] unless available?

          # Ordered explicitly. Without it Postgres may return rows in any
          # order, so `events(...).last` — the obvious way to read the most
          # recent event — is nondeterministic here while the in-memory backend
          # preserves insertion order. Two backends behind one port must not
          # disagree about something a caller can observe.
          #
          # occurred_at alone is not enough: events written in the same batch
          # share a timestamp, so the primary key breaks the tie.
          scope = base_scope
          scope = scope.where(name: name.to_s) if name
          scope = scope.where(occurred_at: since..) if since
          scope = scope.where("dims @> ?", dims.to_json) if dims.any?
          scope.map do |r|
            Event.new(name: r.name, dims: symbolize(r.dims), measures: symbolize(r.measures),
                      occurred_at: r.occurred_at, run_id: r.run_id, trace_id: r.trace_id)
          end
        end

        # Extracted so the ordering invariant is directly assertable — the
        # behaviour it guards cannot be provoked on demand in a test.
        def base_scope = Agentkit::EventRecord.all.order(:occurred_at, :id)

        private

        def symbolize(hash) = (hash || {}).transform_keys(&:to_sym)
      end

      class LogBackend
        def write(batch)
          batch.each do |e|
            Agentkit.logger&.info("[agentkit.telemetry] #{e.name} #{e.dims.to_json} #{e.measures.to_json}")
          end
        end
      end

      # Thin shims — the host wires the real client. Kept here so switching is
      # a config change, not a code change.
      class OtelBackend
        def write(batch)
          return unless defined?(::OpenTelemetry)

          tracer = ::OpenTelemetry.tracer_provider.tracer("agentkit", Agentkit::VERSION)
          batch.each do |e|
            tracer.in_span(e.name, attributes: e.dims.merge(e.measures).transform_keys(&:to_s)) { }
          end
        end
      end

      class StatsdBackend
        def write(batch)
          client = Agentkit.config.telemetry[:statsd_client]
          return unless client

          batch.each do |e|
            tags = e.dims.map { |k, v| "#{k}:#{v}" }
            e.measures.each do |k, v|
              client.gauge("agentkit.#{e.name}.#{k}", v, tags: tags) if v.is_a?(Numeric)
            end
          end
        end
      end
    end
  end
end
