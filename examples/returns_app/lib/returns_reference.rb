# frozen_string_literal: true
require "agentkit"

module ReturnsReference
  K = Agentkit::Knowledge
  class Request < ActiveRecord::Base
    self.table_name = "reference_returns"
    def approval_fingerprint
      K.digest(K::Boundary.data(id: id, tenant: tenant_key, account: account_id,
        requester: requested_by, amount_cents: amount_cents, currency: currency))
    end
  end
  class Intent < ActiveRecord::Base
    self.table_name = "reference_refund_intents"
    belongs_to :return_request, class_name: "ReturnsReference::Request"
  end
  class ProviderRefund < ActiveRecord::Base
    self.table_name = "reference_provider_refunds"
  end

  # Implements an explicit idempotent provider contract. This simulator never
  # contacts a payment service and must not be configured as a production gateway.
  class SimulatedProvider
    def refund(key:, amount_cents:, currency:)
      row = ProviderRefund.create_or_find_by!(provider_key: key) do |record|
        record.amount_cents, record.currency = amount_cents, currency
      end
      raise K::IntegrityError, "provider key reused" unless row.amount_cents == amount_cents && row.currency == currency
      lookup(key: key)
    end

    # nil means authoritative absence, not a timeout or eventual-consistency gap.
    def lookup(key:)
      row = ProviderRefund.find_by(provider_key: key)
      row && { "key" => key, "amount_cents" => row.amount_cents, "currency" => row.currency,
               "reference" => "simulated-refund:#{row.id}" }
    end
  end

  class Workflow
    attr_reader :gate, :learning

    def initialize(authorize:, provider: SimulatedProvider.new, clock: -> { Time.now.utc })
      @authorize, @provider, @clock = authorize, provider, clock
      @journal = K::Journal.new(authorize: ->(_kind, context) { permitted?("journal", context) })
      ontology = K::Ontology.new(name: "ReferenceRefund", version: "1", entities: ["Return"],
        relations: { "ApprovedRefund" => ["Return"] })
      source = K::ActiveRecordSource.new(name: "reference_returns", version: "1", ontology: ontology, rules: [],
        relation: ->(ctx) { requests(ctx) }, authorize: ->(_row, ctx) { permitted?("enqueue", ctx) },
        extract: lambda do |row, ctx, at|
          valid = row.status == "approved" && row.amount_cents.between?(1, 100_000) &&
            row.currency == "MXN" && row.approved_by.present? && row.approved_by != row.requested_by &&
            row.approval_digest == row.approval_fingerprint
          next [] unless valid
          [K::Assertion.new(id: "approved:#{row.id}", scope: K::Boundary.scope(ctx),
            relation: "ApprovedRefund", values: [row.id.to_s], source: "reference_returns/#{row.id}",
            source_version: row.updated_at.utc.iso8601(6), observed_at: at, valid_from: at)]
        end)
      @gate = K::DecisionGate.new(name: "reference_refund", version: "1", source: source, journal: @journal,
        queries: ->(args, _ctx) { [{ "relation" => "ApprovedRefund", "values" => [args.fetch("id").to_s] }] },
        authorize: ->(_args, ctx) { permitted?("enqueue", ctx) })
      @learning = K::BusinessLearning.new(name: "reference_refunds", version: "1",
        objective: "Measure confirmed refund cost", metrics: { refunded_cents: "minimize" },
        constraints: { independent_approval: true }, window_seconds: 60,
        evidence_versions: { gate: gate.digest, provider: "simulator-v1" }, journal: @journal,
        authorize: ->(_action, ctx) { permitted?("learning", ctx) }, clock: clock)
    end

    def request(amount_cents:, context:)
      guard!("request", context)
      raise K::InvalidContract, "bounded integer amount required" unless amount_cents.is_a?(Integer) && amount_cents.between?(1, 100_000)
      requests(context).create!(requested_by: identity(context).fetch("principal"), amount_cents: amount_cents)
    end

    def approve(id:, context:)
      guard!("approve", context)
      row = requests(context).find(id)
      row.with_lock do
        guard!("approve", context)
        raise K::AccessDenied, "independent reviewer required" if row.requested_by == identity(context).fetch("principal")
        raise K::InvalidContract, "request no longer pending" unless row.status == "requested"
        row.update!(status: "approved", approved_by: identity(context).fetch("principal"), approval_digest: row.approval_fingerprint)
      end
    end

    def enqueue(id:, context:)
      gate.execute(arguments: { id: id }, context: context, operation: "reference_refund", idempotency_key: id.to_s) do
        create_intent(id, "reference_refund:#{id}", context)
      end
    end

    # The only effect inside the gate transaction is a local, durable intent.
    def create_intent(id, execution_key, context, queue: "standard")
      row = requests(context).find(id)
      intent = Intent.create!(return_request_id: row.id, provider_key: SecureRandom.uuid,
        execution_key: execution_key, amount_cents: row.amount_cents, currency: row.currency, delivery_queue: queue)
      row.update!(status: "queued")
      { "intent_id" => intent.id }
    end
    private :create_intent

    def claim(id:, context:)
      guard!("deliver", context)
      outside_transaction!
      row = intents(context).find(id)
      row.with_lock do
        guard!("deliver", context)
        if row.status == "sending" && row.lease_until <= @clock.call
          row.update!(status: "unknown")
        end
        next nil unless row.status == "pending"
        row.update!(status: "sending", lease_token: SecureRandom.uuid, lease_until: @clock.call + 60)
        { "id" => row.id, "token" => row.lease_token }
      end
    end

    def deliver(id:, context:)
      lease = claim(id: id, context: context)
      return nil unless lease
      row = intents(context).find(id)
      begin
        confirmation = @provider.refund(key: row.provider_key, amount_cents: row.amount_cents, currency: row.currency)
        row.with_lock do
          guard!("deliver", context)
          raise K::IntegrityError, "stale delivery" unless row.status == "sending" && row.lease_token == lease.fetch("token") && row.lease_until > @clock.call
          confirm!(row, confirmation)
        end
      rescue StandardError
        row.with_lock { row.update!(status: "unknown") if row.status == "sending" && row.lease_token == lease.fetch("token") }
        raise
      end
    end

    def reconcile(id:, context:)
      guard!("reconcile", context)
      outside_transaction!
      row = intents(context).find(id)
      # Lookup has no business effect. An exception leaves the intent unknown.
      confirmation = @provider.lookup(key: row.provider_key)
      row.with_lock do
        guard!("reconcile", context)
        unless row.status == "unknown" || (row.status == "sending" && row.lease_until <= @clock.call)
          raise K::InvalidContract, "only uncertain deliveries can be reconciled"
        end
        confirmation ? confirm!(row, confirmation) : row.update!(status: "pending", lease_token: nil, lease_until: nil)
      end
    end

    def record_outcome(id:, context:)
      guard!("learning", context)
      row = intents(context).find(id)
      raise K::InvalidContract, "provider confirmation required" unless row.status == "confirmed"
      existing = learning.fetch(type: "outcome", id: row.id.to_s, context: context)
      return existing if existing
      learning.observe(id: row.id.to_s, execution_key: row.execution_key, context: context)
      # The core enforces the maturity window. A successful enqueue is not a refund.
      learning.outcome(id: row.id.to_s, values: { refunded_cents: row.amount_cents },
        source: row.confirmation.fetch("reference"), source_version: K.digest(row.confirmation),
        observed_at: @clock.call.iso8601(6), context: context)
    end

    def pilot(starts_at:, enrollment_ends_at:, analysis_at:)
      K::BusinessExperiment.new(name: "reference_refund_routing", version: "1",
        hypothesis: "specialist review reduces handling time without changing refund policy", unit: "return",
        metrics: { handling_seconds: { min: 0, max: 3600, direction: "minimize" } }, primary_metric: "handling_seconds",
        starts_at: starts_at.iso8601(6), enrollment_ends_at: enrollment_ends_at.iso8601(6), analysis_at: analysis_at.iso8601(6),
        window_seconds: 60, max_units: 100, min_per_arm: 20,
        gates: { control: gate.digest, treatment: gate.digest },
        variants: { control: { queue: "standard" }, treatment: { queue: "specialist" } },
        evidence_versions: { policy: "1", timing: "host-v1" }, journal: @journal,
        authorize: ->(_action, ctx) { permitted?("experiment", ctx) },
        eligible: ->(unit, ctx) { requests(ctx).where(id: unit, status: "approved").exists? },
        bind_unit: ->(unit, args, _ctx) { unit.to_s == args.fetch("id").to_s }, clock: @clock)
    end

    def enqueue_pilot(id:, pilot:, context:)
      guard!("experiment", context)
      Intent.transaction do
        result = pilot.execute(unit_id: id.to_s, gate: gate, arguments: { id: id }, context: context) do |_arm, variant|
          create_intent(id, "pending-experiment-receipt", context, queue: variant.fetch("queue"))
        end
        intents(context).find(result.fetch("output").fetch("intent_id")).update!(execution_key: result.fetch("execution_key"))
        result
      end
    end

    private

    def confirm!(row, confirmation)
      unless confirmation.is_a?(Hash) && confirmation.values_at("key", "amount_cents", "currency") == [row.provider_key, row.amount_cents, row.currency] && confirmation["reference"].is_a?(String) && !confirmation["reference"].empty?
        raise K::IntegrityError, "provider confirmation mismatch"
      end
      row.update!(status: "confirmed", confirmation: confirmation, lease_token: nil, lease_until: nil)
      row.return_request.update!(status: "refunded")
    end

    def identity(context) = K::Boundary.identity(context)
    def permitted?(action, context) = @authorize.call(action, context) == true
    def guard!(action, context)
      identity(context)
      raise K::AccessDenied, "host policy denied #{action}" unless permitted?(action, context)
    end
    def requests(context)
      scope = identity(context)
      raise K::AccessDenied, "account required" if scope.fetch("account").empty?
      Request.where(tenant_key: scope.fetch("tenant"), account_id: scope.fetch("account"))
    end
    def intents(context) = Intent.where(return_request_id: requests(context).select(:id))
    def outside_transaction!
      raise K::InvalidContract, "provider work must run outside caller transactions" if Intent.connection.transaction_open?
    end
  end
end
