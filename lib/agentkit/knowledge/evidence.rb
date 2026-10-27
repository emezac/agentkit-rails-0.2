# frozen_string_literal: true

module Agentkit
  module Knowledge
    class AccessDenied < Error; end
    class IntegrityError < Error; end
    class DecisionDenied < Error; end

    module Boundary
      module_function

      def identity(context)
        unless context.respond_to?(:tenant_key) && context.respond_to?(:principal) && context.respond_to?(:account)
          raise AccessDenied, "authenticated execution context required"
        end
        tenant = context.tenant_key.to_s
        principal = context.principal
        actor = principal.respond_to?(:id) ? principal.id.to_s : principal.to_s
        raise AccessDenied, "explicit tenant and principal required" if tenant.empty? || actor.empty?
        if principal.respond_to?(:tenant_key) && principal.tenant_key && principal.tenant_key.to_s != tenant
          raise AccessDenied, "principal tenant mismatch"
        end
        account = context.account.respond_to?(:id) ? context.account.id : context.account
        { "tenant" => tenant, "account" => account.nil? ? "" : account.to_s, "principal" => actor }
      end

      def scope(context)
        identity = identity(context)
        "knowledge:#{Knowledge.digest(identity.slice('tenant', 'account'))}"
      end

      def data(value)
        normalized = case value
                     when Hash
                       keys = value.keys.map(&:to_s)
                       raise InvalidContract, "ambiguous keys" unless keys.uniq == keys
                       value.to_h { |key, item| [key.to_s, data(item)] }
                     when Array then value.map { |item| data(item) }
                     else value
                     end
        Knowledge.copy(normalized)
      end
    end

    # Scoped durable data and inbox. Callbacks authorize reads AND writes; this
    # class is not an HTTP endpoint and never infers authority from LLM arguments.
    class Journal
      MAX_BYTES = 16 * 1024 * 1024
      KINDS = %w[snapshot decision execution event delivery learning experiment abstraction operations].freeze

      def initialize(authorize:)
        raise InvalidContract, "journal authorizer required" unless authorize.respond_to?(:call)
        @authorize = authorize
        freeze
      end

      def model
        unless defined?(Agentkit::KnowledgeEntryRecord) && Agentkit::KnowledgeEntryRecord.table_exists?
          raise InvalidContract, "Rails knowledge persistence requires migration 024"
        end
        Agentkit::KnowledgeEntryRecord
      end

      def append(kind:, key:, payload:, context:)
        payload = bounded(payload)
        digest = Knowledge.digest(payload)
        once(kind: kind, key: key, request_digest: digest, context: context) { payload }
      end

      def read(kind:, key:, context:)
        row = relation(kind, context).find_by(entry_key: entry_key(key))
        row && checked_payload(row)
      end

      def save_snapshot(snapshot, context:)
        raise AccessDenied, "snapshot scope mismatch" unless snapshot.data.fetch("scope") == Boundary.scope(context)
        append(kind: "snapshot", key: snapshot.digest, payload: snapshot.to_h, context: context)
        snapshot.digest
      end

      def load_snapshot(digest, context:)
        payload = read(kind: "snapshot", key: digest, context: context)
        return nil unless payload
        snapshot = Snapshot.from_json(JSON.generate(payload))
        unless snapshot.digest == digest && snapshot.data.fetch("scope") == Boundary.scope(context)
          raise IntegrityError, "snapshot identity mismatch"
        end
        snapshot
      end

      def record_event(id:, payload:, context:)
        append(kind: "event", key: id, payload: { "id" => Knowledge.text(id), "data" => payload }, context: context)
      end

      def save_abstraction(connection, context:)
        raise InvalidContract, "verified GaloisConnection required" unless connection.is_a?(GaloisConnection)
        append(kind: "abstraction", key: "connection:#{connection.digest}", payload: connection.to_h, context: context)
        connection.digest
      end

      def load_abstraction(digest, context:)
        payload = read(kind: "abstraction", key: "connection:#{digest}", context: context)
        return nil unless payload
        connection = GaloisConnection.from_json(JSON.generate(payload))
        raise IntegrityError, "abstraction digest mismatch" unless connection.digest == digest
        connection
      end

      def save_abstraction_view(view, context:)
        raise InvalidContract, "verified AbstractionView required" unless view.is_a?(AbstractionView)
        unless load_snapshot(view.data.fetch("snapshot_digest"), context: context) &&
               load_abstraction(view.data.fetch("connection_digest"), context: context)
          raise AccessDenied, "view requires snapshot and connection stored in current scope"
        end
        append(kind: "abstraction", key: "view:#{view.digest}", payload: view.to_h, context: context)
        view.digest
      end

      # Retry this method after a worker crash. Same-database effects and the
      # delivery marker commit together; an exception leaves the event pending.
      def consume_event(id:, context:)
        event = read(kind: "event", key: id, context: context)
        raise InvalidContract, "unknown evidence event" unless event
        once(kind: "delivery", key: id, request_digest: Knowledge.digest(event), context: context) do
          yield event.fetch("data")
          { "event_id" => id, "processed" => true }
        end
      end

      def pending_event_ids(context:, limit: 100)
        raise InvalidContract, "limit must be 1..1000" unless limit.is_a?(Integer) && (1..1000).cover?(limit)
        delivered = relation("delivery", context).where(state: "complete").select(:entry_key)
        relation("event", context).where.not(entry_key: delivered).order(:id).limit(limit).map do |row|
          checked_payload(row).fetch("id")
        end
      end

      # Row locking plus a unique index serialize duplicate execution/delivery.
      # Request digests must include arguments, principal and contract version.
      def once(kind:, key:, request_digest:, context:)
        Knowledge.text(request_digest)
        relation = relation(kind, context)
        identity = Boundary.identity(context)
        output = nil
        model.transaction(requires_new: true) do
          row = relation.create_or_find_by!(entry_key: entry_key(key)) do |record|
            record.tenant_key = identity.fetch("tenant")
            record.account_key = identity.fetch("account")
            record.request_digest = request_digest
            record.payload_digest = Knowledge.digest({})
            record.state = "running"
            record.payload = {}
          end
          row.lock!
          raise IntegrityError, "idempotency key reused with different request" unless row.request_digest == request_digest
          if row.state == "complete"
            output = checked_payload(row)
          else
            output = bounded(yield)
            row.update!(state: "complete", payload: output, payload_digest: Knowledge.digest(output))
          end
        end
        raise IntegrityError, "knowledge transaction rolled back" unless output
        output
      end

      private

      def entry_key(key) = Knowledge.digest(Knowledge.text(key))

      def relation(kind, context)
        raise InvalidContract, "unknown journal kind" unless KINDS.include?(kind)
        identity = Boundary.identity(context)
        raise AccessDenied, "journal access denied" unless @authorize.call(kind, context) == true
        model.where(scope_key: Boundary.scope(context), tenant_key: identity.fetch("tenant"),
                    account_key: identity.fetch("account"), kind: kind)
      end

      def checked_payload(row)
        raise IntegrityError, "incomplete journal entry" unless row.state == "complete"
        payload = bounded(row.payload)
        raise IntegrityError, "journal payload digest mismatch" unless Knowledge.digest(payload) == row.payload_digest
        payload
      end

      def bounded(value)
        payload = Boundary.data(value)
        raise InvalidContract, "journal payload must be an object" unless payload.is_a?(Hash)
        raise InvalidContract, "journal byte limit exceeded" if JSON.generate(payload).bytesize > MAX_BYTES
        payload
      end
    end

    class ActiveRecordSource
      attr_reader :contract

      def initialize(name:, version:, ontology:, rules:, relation:, authorize:, extract:, subject_key: "id")
        [name, version, subject_key].each { |value| Knowledge.text(value) }
        [relation, authorize, extract].each do |callback|
          raise InvalidContract, "source callbacks required" unless callback.respond_to?(:call)
        end
        @ontology, @rules = ontology, rules.dup.freeze
        @relation, @authorize, @extract, @subject_key = relation, authorize, extract, Knowledge.text(subject_key)
        @contract = Knowledge.copy("name" => name, "version" => version, "ontology" => ontology.digest,
                                   "rules" => rules.map(&:digest).sort, "subject_key" => subject_key)
        freeze
      end

      # A single root row is locked until the caller's block finishes. The host
      # must lock any additional mutable rows read by extract in a stable order.
      def with_snapshot(arguments:, context:, journal:)
        Boundary.identity(context)
        args = Boundary.data(arguments)
        relation = @relation.call(context)
        unless defined?(::ActiveRecord::Relation) && relation.is_a?(::ActiveRecord::Relation)
          raise InvalidContract, "source must return an ActiveRecord relation"
        end
        unless relation.klass.connection_pool.equal?(journal.model.connection_pool)
          raise InvalidContract, "source and journal must share a database connection pool"
        end
        subject = args.fetch(@subject_key) { raise InvalidContract, "missing subject argument" }
        unless subject.is_a?(String) || subject.is_a?(Integer)
          raise InvalidContract, "subject must be a scalar id"
        end
        completed, output = false, nil
        relation.klass.transaction(requires_new: true) do
          record = relation.lock.find(subject)
          identity = Boundary.identity(context)
          if record.respond_to?(:tenant_key) && record.tenant_key.to_s != identity.fetch("tenant")
            raise AccessDenied, "record tenant mismatch"
          end
          if record.respond_to?(:account_id) && (identity.fetch("account").empty? || record.account_id.to_s != identity.fetch("account"))
            raise AccessDenied, "record account mismatch"
          end
          raise AccessDenied, "source access denied" unless @authorize.call(record, context) == true
          at = Time.now.utc.iso8601(6)
          facts = @extract.call(record, context, at)
          snapshot = Snapshot.new(ontology: @ontology, rules: @rules, facts: facts,
                                  scope: Boundary.scope(context), at: at)
          output = yield snapshot
          completed = true
        end
        raise IntegrityError, "source transaction rolled back" unless completed
        output
      end
    end
  end
end
