# frozen_string_literal: true

module Agentkit
  module Operations
    # Durable, scoped notification outbox. Provider effects are at-least-once;
    # a delivery receipt never substitutes for an authorized human acknowledgement.
    class Escalations
      def initialize(journal:, authorize:, clock: -> { Time.now.utc }, ack_timeout: 900, retry_after: 60, max_attempts: 3, lease_seconds: 60)
        unless [authorize, clock].all? { |c| c.respond_to?(:call) } &&
               [ack_timeout, retry_after, max_attempts, lease_seconds].all? { |v| v.is_a?(Integer) && v.positive? }
          raise K::InvalidContract, "callbacks and positive escalation limits required"
        end
        @journal, @authorize, @clock = journal, authorize, clock
        @policy = B.data(ack_timeout: ack_timeout, retry_after: retry_after, max_attempts: max_attempts, lease_seconds: lease_seconds)
      end

      def enqueue(id:, incident_id:, incident_digest:, primary:, fallback:, reasons:, context:)
        guard!("escalate", context)
        [id, incident_id, primary, fallback].each { |v| K.text(v) }
        unless /\A[0-9a-f]{64}\z/.match?(incident_digest.to_s) && reasons.is_a?(Array) && reasons.size.between?(1, 128)
          raise K::InvalidContract, "incident digest and bounded escalation reasons required"
        end
        reasons.each { |r| K.text(r) }
        payload = B.data(id: id, incident_id: incident_id, incident_digest: incident_digest,
          targets: [primary, fallback], reasons: reasons, policy: @policy)
        raise K::InvalidContract, "escalation exceeds 64 KiB" if JSON.generate(payload).bytesize > 65_536
        result = model.transaction(requires_new: true) do
          row = relation(context).create_or_find_by!(entry_key: key(id)) do |r|
            r.request_digest = K.digest(payload)
            r.payload = payload
            r.ack_due_at = now + @policy.fetch("ack_timeout")
            r.next_attempt_at = now
          end
          row.with_lock do
            check!(row)
            raise K::IntegrityError, "escalation identity conflict" unless row.request_digest == K.digest(payload)
            @journal.append(kind: "operations", key: K.digest(["escalation", id]), payload: payload, context: context)
            state(row)
          end
        end
        result || raise(K::IntegrityError, "escalation transaction rolled back")
      end

      def fetch(id:, context:)
        guard!("read", context)
        row = relation(context).find_by(entry_key: key(id))
        row && state(row)
      end

      def due(context:, limit: 100)
        guard!("read", context)
        raise K::InvalidContract, "limit must be 1..1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)
        relation(context).where(status: "open").where("next_attempt_at <= ? AND (lease_until IS NULL OR lease_until <= ?)", now, now)
          .order(:next_attempt_at, :id).limit(limit).map { |row| state(row) }
      end

      def list(context:, status: nil, limit: 100)
        guard!("read", context)
        unless (status.nil? || %w[open acknowledged exhausted].include?(status)) && limit.is_a?(Integer) && limit.between?(1, 1000)
          raise K::InvalidContract, "valid status and limit 1..1000 required"
        end
        rows = relation(context)
        rows = rows.where(status: status) if status
        rows.order(updated_at: :desc, id: :desc).limit(limit).map { |row| state(row) }
      end

      def deliver(id:, sender:, context:)
        guard!("deliver", context)
        raise K::InvalidContract, "sender callback required" unless sender.respond_to?(:call)
        # External IO cannot be safe inside a caller-owned DB transaction either.
        raise K::InvalidContract, "deliver must run outside a transaction" if model.connection.transaction_open?
        claim = nil
        row = relation(context).find_by!(entry_key: key(id))
        locked = row.with_lock do
          guard!("deliver", context)
          check!(row)
          if row.status == "open" && (!row.lease_until || row.lease_until <= now)
            policy = row.payload.fetch("policy")
            if row.ack_due_at <= now
              if row.target_index.zero?
                row.target_index = 1
                row.attempts = 0
                row.delivered_at = nil
                row.ack_due_at = now + policy.fetch("ack_timeout")
                row.next_attempt_at = now
                audit(row, "fallback", {}, context)
              else
                row.status = "exhausted"
                audit(row, "exhausted", {}, context)
              end
            end
            if row.status == "open" && !row.delivered_at && row.next_attempt_at <= now && row.attempts < policy.fetch("max_attempts")
              row.attempts += 1
              row.lease_token = SecureRandom.uuid
              row.lease_until = now + policy.fetch("lease_seconds")
              claim = B.data(token: row.lease_token, target_index: row.target_index, attempt: row.attempts,
                notification: { id: id, incident_id: row.payload.fetch("incident_id"), incident_digest: row.payload.fetch("incident_digest"),
                  reasons: row.payload.fetch("reasons"), target: row.payload.fetch("targets").fetch(row.target_index),
                  idempotency_key: K.digest([row.scope_key, row.entry_key, row.target_index]) })
              audit(row, "claimed:#{claim['token']}", claim.except("notification"), context)
            elsif row.status == "open"
              row.next_attempt_at = row.ack_due_at if row.delivered_at || row.attempts >= policy.fetch("max_attempts")
            end
            row.save!
          end
          true
        end
        raise K::IntegrityError, "delivery claim rolled back" unless locked
        return state(row) unless claim

        receipt, failure = nil, nil
        begin
          receipt = K.text(sender.call(claim.fetch("notification"), context))
          raise K::InvalidContract, "receipt exceeds 4096 bytes" if receipt.bytesize > 4096
        rescue StandardError => error
          receipt = nil
          failure = error.class.name
        end
        result = row.with_lock do
          check!(row)
          # An expired lease may have been claimed by another worker or ACKed.
          audit(row, "attempt:#{claim['token']}", { "target_index" => claim["target_index"], "attempt" => claim["attempt"],
            "receipt" => receipt, "error_class" => failure, "stale" => row.lease_token != claim["token"] }, context)
          if row.lease_token == claim["token"]
            row.lease_token = row.lease_until = nil
            if row.status == "open"
              row.delivered_at = now unless failure
              row.next_attempt_at = failure && row.attempts < row.payload.fetch("policy").fetch("max_attempts") ?
                [now + row.payload.fetch("policy").fetch("retry_after"), row.ack_due_at].min : row.ack_due_at
            end
            row.save!
          end
          state(row)
        end
        result || raise(K::IntegrityError, "delivery receipt transaction rolled back")
      end

      def acknowledge(id:, reason:, context:)
        guard!("acknowledge", context) # Host must authenticate and authorize a HUMAN.
        actor = B.identity(context).fetch("principal")
        request = B.data(id: K.text(id), reason: K.text(reason), actor: actor)
        row = relation(context).find_by!(entry_key: key(id))
        result = row.with_lock do
          guard!("acknowledge", context)
          check!(row)
          @journal.once(kind: "operations", key: K.digest(["ack", id]), request_digest: K.digest(request), context: context) do
            row.update!(status: "acknowledged", acknowledged_at: now, acknowledged_by: actor, lease_token: nil, lease_until: nil)
            request.merge("acknowledged_at" => now.iso8601(6))
          end
          state(row)
        end
        result || raise(K::IntegrityError, "acknowledgement transaction rolled back")
      end

      private

      def now = @clock.call.utc
      def key(id) = K.digest(K.text(id))
      def guard!(action, context)
        B.identity(context)
        raise K::AccessDenied, "operations access denied" unless @authorize.call(action, context) == true
      end

      def model
        unless defined?(Agentkit::OperationsEscalationRecord) && Agentkit::OperationsEscalationRecord.table_exists?
          raise K::InvalidContract, "operations escalation requires migration 026"
        end
        unless Agentkit::OperationsEscalationRecord.connection_pool.equal?(@journal.model.connection_pool)
          raise K::InvalidContract, "operations and journal must share a database pool"
        end
        Agentkit::OperationsEscalationRecord
      end

      def relation(context) = model.where(scope_key: B.scope(context))
      def check!(row)
        raise K::IntegrityError, "escalation payload changed" unless K.digest(row.payload) == row.request_digest
      end

      def state(row)
        check!(row)
        B.data(row.payload.merge("status" => row.status, "target_index" => row.target_index, "attempts" => row.attempts,
          "ack_due_at" => row.ack_due_at.iso8601(6), "next_attempt_at" => row.next_attempt_at.iso8601(6),
          "delivered_at" => row.delivered_at&.iso8601(6), "acknowledged_at" => row.acknowledged_at&.iso8601(6),
          "acknowledged_by" => row.acknowledged_by))
      end

      def audit(row, event, details, context)
        @journal.append(kind: "operations", key: K.digest(["escalation_event", row.payload.fetch("id"), event]),
          payload: details.merge("id" => row.payload.fetch("id"), "event" => event, "at" => now.iso8601(6)), context: context)
      end
    end
  end
end
