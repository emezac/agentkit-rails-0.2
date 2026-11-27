# frozen_string_literal: true

module Agentkit
  module Memory
    # Bridges host source-change events to reviewed-memory invalidation with a
    # Journal delivery marker. Historical evidence remains host-governed data.
    class EvidenceLifecycle
      K = Knowledge
      B = K::Boundary
      PREFIX = "source_lifecycle:"

      def initialize(journal:, consolidation:, authorize:)
        unless journal.is_a?(K::Journal) && consolidation.is_a?(Consolidation) && authorize.respond_to?(:call)
          raise K::InvalidContract, "Journal, consolidation and authorizer required"
        end
        unless journal.model.connection_pool.equal?(consolidation.journal.model.connection_pool)
          raise K::InvalidContract, "lifecycle and memory must share a database pool"
        end
        @journal, @consolidation, @authorize = journal, consolidation, authorize
      end

      # Call after the host source update commits. Reusing an ID for another
      # source or version conflicts in Journal instead of replacing evidence.
      def record(id:, reference:, source_digest:, change:, reason:, context:)
        payload = B.data(type: "source_lifecycle", id: identifier(id),
          reference: bounded(reference), source_digest: digest(source_digest),
          change: change, reason: bounded(reason))
        raise K::InvalidContract, "changed or deleted required" unless %w[changed deleted].include?(payload.fetch("change"))
        guard!("record", payload, context)
        @journal.record_event(id: event_id(id), payload: payload, context: context)
      end

      # Journal's delivery marker and every affected memory revision share the
      # database transaction. Failure leaves the event pending for replay.
      def consume(id:, context:)
        key = event_id(identifier(id))
        guard!("consume", { "id" => id }, context)
        delivery = @journal.consume_event(id: key, context: context) do |payload|
          unless payload.is_a?(Hash) && payload.fetch("type") == "source_lifecycle" && payload.fetch("id") == id
            raise K::IntegrityError, "wrong lifecycle event"
          end
          guard!("consume", payload, context)
          @consolidation.invalidate(reference: payload.fetch("reference"),
            reason: payload.fetch("reason"), context: context)
        end
        B.data(delivery: delivery, authorizes: false)
      end

      private

      def event_id(id) = "#{PREFIX}#{identifier(id)}"
      def identifier(value)
        raise K::InvalidContract, "bounded event ID required" unless value.is_a?(String) && value.bytesize.between?(1, 128) && value.match?(/\A[a-zA-Z0-9:._-]+\z/)
        value
      end
      def bounded(value)
        raise K::InvalidContract, "bounded text required" unless value.is_a?(String) && value.bytesize.between?(1, 4096)
        value
      end
      def digest(value)
        raise K::InvalidContract, "SHA-256 digest required" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
        value
      end
      def guard!(action, payload, context)
        B.identity(context)
        raise K::AccessDenied, "source lifecycle denied" unless @authorize.call(action, B.data(payload), context) == true
      end
    end
  end
end
