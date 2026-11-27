# frozen_string_literal: true

require "thread"

module Agentkit
  module Telemetry
    # Process-local, bounded delivery. Only idempotent sinks are retried after
    # ambiguous failures. This is not a durable outbox or evidence ledger.
    class Delivery
      LIMIT = 10_000

      def initialize
        @lock, @flush_lock = Mutex.new, Mutex.new
        @buffer, @pending = [], {}
        @dropped, @failures, @pending_count = 0, 0, 0
      end

      def enqueue(event)
        @lock.synchronize do
          if @buffer.size >= LIMIT
            @dropped += 1
          else
            @buffer << event
          end
          @buffer.size
        end
      end

      def buffer = @lock.synchronize { @buffer.dup }

      def health
        @lock.synchronize do
          { buffered_events: @buffer.size, pending_deliveries: @pending_count,
            dropped_deliveries: @dropped, failed_writes: @failures,
            complete: !@inflight && @buffer.empty? && @pending_count.zero? && @dropped.zero? && @failures.zero? }
        end
      end

      def flush(backends)
        # A backend can emit telemetry itself; never deadlock on a recursive flush.
        return [] unless @flush_lock.try_lock

        begin
          batch = @lock.synchronize { @inflight = true; current = @buffer; @buffer = []; current }
          # Keep failed deliveries attached to their original sink, even if the
          # host changes its configured backends between flushes.
          backends.uniq.each do |backend|
            queue = (@pending[backend] ||= [])
            room = LIMIT - queue.size
            queue.concat(batch.first(room))
            @lock.synchronize { @dropped += [batch.size - room, 0].max }
          end
          @lock.synchronize do
            @dropped += batch.size if backends.empty?
            @pending_count = @pending.values.sum(&:size)
          end
          @pending.keys.each do |backend|
            queue = @pending.fetch(backend)
            next if queue.empty?

            begin
              result = backend.write(queue.dup.freeze)
              raise IOError, "telemetry backend unavailable" if result == false

              @pending.delete(backend)
            rescue StandardError => error
              retryable = backend.respond_to?(:idempotent?) && backend.idempotent?
              @lock.synchronize do
                @failures += 1
                @dropped += queue.size unless retryable
              end
              @pending.delete(backend) unless retryable
              # Do not log exception messages: a sink may include payload data.
              begin
                Agentkit.logger&.warn("[AgentKit::Telemetry] write failed (#{error.class})")
              rescue StandardError
                # Diagnostics cannot break the measured business operation.
              end
            ensure
              @lock.synchronize { @pending_count = @pending.values.sum(&:size) }
            end
          end
          batch
        ensure
          @lock.synchronize { @inflight = false }
          @flush_lock.unlock
        end
      end
    end
  end
end
