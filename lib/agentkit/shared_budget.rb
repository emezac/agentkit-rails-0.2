# frozen_string_literal: true

require "bigdecimal"

module Agentkit
  # Opt-in durable admission for host-controlled execution boundaries. The host
  # chooses the billing ledger/path and enforces actual provider-side limits.
  class SharedBudget
    K = Knowledge
    B = K::Boundary
    RESOURCES = %w[cost_microusd tokens].freeze
    MAX_INTEGER = (2**63) - 1

    # Conservative conversion of a measured AgentLoop outcome. Unknown calls
    # remain reserved until an operator reconciles provider accounting.
    def self.loop_usage(outcome)
      snapshot = outcome.budget
      unless snapshot.is_a?(Hash) && snapshot.fetch(:unmeasured_calls).zero? && snapshot.fetch(:unpriced_models).empty?
        raise K::InvalidContract, "loop consumption requires reconciliation"
      end
      cost = outcome.usage.cost_usd
      unless cost.is_a?(Numeric) && cost.finite? && cost >= 0
        raise K::InvalidContract, "invalid measured loop cost"
      end
      { cost_microusd: (BigDecimal(cost.to_s) * 1_000_000).ceil, tokens: outcome.usage.total_tokens }
    end

    def initialize(journal:, authorize:, clock: -> { Time.now.utc })
      raise K::InvalidContract, "trusted callbacks required" unless authorize.respond_to?(:call) && clock.respond_to?(:call)
      @journal, @authorize, @clock = journal, authorize, clock
    end

    def define(id:, nodes:, expires_at:, context:)
      id = text(id)
      deadline = timestamp(expires_at)
      raise K::InvalidContract, "future budget deadline required" unless Time.iso8601(deadline) > now
      raise K::InvalidContract, "1..128 budget nodes required" unless nodes.is_a?(Array) && nodes.size.between?(1, 128)
      nodes = nodes.map do |node|
        node = B.data(node)
        exact!(node, %w[path limits])
        path = path(node.fetch("path"))
        limits = quantities(node.fetch("limits"), concurrency: true)
        raise K::InvalidContract, "positive concurrency required" unless limits["concurrency"].positive?
        { "path" => path, "limits" => limits }
      end.sort_by { |node| key(node.fetch("path")) }
      paths = nodes.map { |node| node.fetch("path") }
      unless paths.uniq == paths && paths.include?([]) && paths.all? { |p| p.empty? || paths.include?(p[0...-1]) }
        raise K::InvalidContract, "unique rooted budget tree required"
      end
      contract = B.data(id: id, nodes: nodes, expires_at: deadline)
      guard!("define", contract, context)
      pools!
      model.transaction do
        row = scope(context).create_or_find_by!(budget_key: id) do |record|
          record.contract, record.contract_digest = contract, K.digest(contract)
          record.usage = paths.to_h { |p| [key(p), { "cost_microusd" => 0, "tokens" => 0, "concurrency" => 0 }] }
        end
        row.with_lock do
          guard!("define", contract, context)
          raise K::IntegrityError, "budget contract changed" unless row.contract_digest == K.digest(contract)
          audit(row, "contract", contract, context)
          view(row)
        end
      end
    end

    def reserve(id:, key:, path:, amounts:, expires_at:, context:)
      # A caller-owned savepoint cannot commit a reservation before external work.
      pools!
      raise K::InvalidContract, "reserve outside caller transactions" if model.connection.transaction_open?
      request = B.data(key: text(key), path: self.path(path), amounts: quantities(amounts),
        expires_at: timestamp(expires_at), identity: B.identity(context))
      locked(id, "reserve", request, context) do |row|
        previous = reservations(row).find_by(reservation_key: request.fetch("key"))
        if previous
          raise K::IntegrityError, "reservation key reused" unless previous.request_digest == K.digest(request)
          next receipt(previous).merge("newly_reserved" => false)
        end
        deadline = Time.iso8601(request.fetch("expires_at"))
        unless deadline > now && deadline <= Time.iso8601(row.contract.fetch("expires_at"))
          raise K::InvalidContract, "reservation deadline outside billing window"
        end
        ancestors = ancestors!(row, request.fetch("path"))
        ancestors.each do |node|
          usage = row.usage.fetch(self.key(node.fetch("path")))
          request.fetch("amounts").merge("concurrency" => 1).each do |resource, amount|
            proposed = usage.fetch(resource) + amount
            limit = node.fetch("limits").fetch(resource)
            raise BudgetExceeded.new(resource: resource, limit: limit, used: proposed) if proposed > limit
          end
        end
        adjust!(row, request.fetch("path"), request.fetch("amounts").merge("concurrency" => 1))
        reservation = reservations(row).create!(reservation_key: request.fetch("key"), request: request,
          request_digest: K.digest(request), status: "reserved")
        audit(row, "reserve:#{reservation.id}", receipt(reservation), context)
        receipt(reservation).merge("newly_reserved" => true)
      end
    end

    def unknown(id:, key:, context:)
      transition(id, key, "unknown", context) do |row, reservation|
        if reservation.status == "reserved"
          reservation.update!(status: "unknown")
          audit(row, "unknown:#{reservation.id}", receipt(reservation), context)
        end
        receipt(reservation)
      end
    end

    def settle(id:, key:, actual:, evidence:, context:, reconcile: false)
      raise K::InvalidContract, "boolean reconciliation mode required" unless [true, false].include?(reconcile)
      actual = quantities(actual)
      settlement = B.data(actual: actual, evidence: text(evidence))
      action = reconcile ? "reconcile" : "settle"
      transition(id, key, action, context, settlement) do |row, reservation|
        if reservation.status == "settled"
          raise K::IntegrityError, "conflicting settlement" unless reservation.settlement == settlement
          next receipt(reservation)
        end
        uncertain = reservation.status == "unknown" || Time.iso8601(reservation.request.fetch("expires_at")) <= now
        raise K::AccessDenied, "authorized reconciliation required" if uncertain && !reconcile
        reserved = reservation.request.fetch("amounts")
        delta = RESOURCES.to_h { |resource| [resource, actual.fetch(resource) - reserved.fetch(resource)] }
        # Always record actual overspend. Rolling this back would hide the bill.
        adjust!(row, reservation.request.fetch("path"), delta.merge("concurrency" => -1))
        reservation.update!(status: "settled", settlement: settlement)
        audit(row, "settle:#{reservation.id}", receipt(reservation), context)
        receipt(reservation)
      end
    end

    def fetch(id:, context:)
      locked(id, "read", {}, context) { |row| view(row) }
    end

    def reservation(id:, key:, context:)
      transition(id, key, "read_reservation", context) { |_row, record| receipt(record) }
    end

    # A common wrapper for an AgentLoop, exploration probe or worker attempt.
    # It deliberately refuses duplicate dispatch rather than repeating effects.
    def run(id:, key:, path:, amounts:, expires_at:, evidence:, measure:, context:)
      raise K::InvalidContract, "usage mapper required" unless measure.respond_to?(:call)
      grant = reserve(id: id, key: key, path: path, amounts: amounts, expires_at: expires_at, context: context)
      raise K::IntegrityError, "reservation already exists; reconcile instead of redispatching" unless grant.fetch("newly_reserved")
      begin
        value = yield
        result = settle(id: id, key: key, actual: measure.call(value), evidence: evidence, context: context)
        { value: value, receipt: result }
      rescue StandardError => failure
        begin
          unknown(id: id, key: key, context: context)
        rescue StandardError
          # The durable reservation still holds capacity if status recording
          # fails due to revocation or a database outage.
        end
        raise failure
      end
    end

    private

    def transition(id, reservation_key, action, context, extra = {})
      locked(id, action, extra.merge("key" => text(reservation_key)), context) do |row|
        record = reservations(row).find_by!(reservation_key: reservation_key)
        # Reconciliation can belong to a different operator, but only through
        # its own explicitly authorized action. Ordinary receipts are owner-bound.
        unless action == "reconcile" || record.request.fetch("identity") == B.identity(context)
          raise K::AccessDenied, "reservation owner mismatch"
        end
        guard!(action, { "id" => id, "request" => record.request, "settlement" => extra }, context)
        yield row, record
      end
    end

    def locked(id, action, request, context)
      pools!
      guard!(action, request.merge("id" => text(id)), context)
      row = scope(context).find_by!(budget_key: id)
      row.with_lock do
        raise K::IntegrityError, "budget contract mismatch" unless K.digest(row.contract) == row.contract_digest
        guard!(action, request.merge("id" => id), context)
        yield row
      end
    end

    def adjust!(row, path, delta)
      usage = row.usage.deep_dup
      ancestors!(row, path).each do |node|
        counters = usage.fetch(key(node.fetch("path")))
        delta.each { |resource, amount| counters[resource] += amount }
      end
      row.update!(usage: usage)
    end

    def ancestors!(row, path)
      nodes = row.contract.fetch("nodes")
      raise K::InvalidContract, "undeclared budget path" unless nodes.any? { |node| node.fetch("path") == path }
      nodes.select { |node| path.first(node.fetch("path").size) == node.fetch("path") }
    end

    def receipt(record)
      actual, reserved = record.settlement&.fetch("actual"), record.request.fetch("amounts")
      B.data(key: record.reservation_key, status: record.status, request: record.request,
        settlement: record.settlement, overdue: record.status != "settled" && Time.iso8601(record.request.fetch("expires_at")) <= now,
        overrun: actual && RESOURCES.any? { |resource| actual.fetch(resource) > reserved.fetch(resource) }, authorizes: false)
    end

    def view(row) = B.data(id: row.budget_key, contract: row.contract, usage: row.usage, authorizes: false)
    def audit(row, suffix, payload, context)
      @journal.append(kind: "budget", key: "#{row.contract_digest}:#{suffix}", payload: payload, context: context)
    end
    def model = Agentkit::SharedBudgetRecord
    def scope(context) = model.where(tenant_key: B.identity(context).fetch("tenant"))
    def reservations(row) = Agentkit::BudgetReservationRecord.where(shared_budget_id: row.id)
    def pools!
      unless model.connection_pool.equal?(@journal.model.connection_pool) && model.connection_pool.equal?(Agentkit::BudgetReservationRecord.connection_pool)
        raise K::InvalidContract, "budget and Journal must share a database pool"
      end
    end
    def guard!(action, request, context)
      B.identity(context)
      raise K::AccessDenied, "shared budget access denied" unless @authorize.call(action, B.data(request), context) == true
    end
    def now = @clock.call.utc
    def timestamp(value) = K.timestamp(value)
    def text(value)
      raise K::InvalidContract, "bounded identifier required" unless value.is_a?(String) && value.bytesize.between?(1, 256)
      value
    end
    def path(value)
      raise K::InvalidContract, "path must have at most four levels" unless value.is_a?(Array) && value.size <= 4
      value.map { |part| text(part) }
    end
    def key(path) = JSON.generate(path)
    def exact!(value, keys)
      raise K::InvalidContract, "invalid fields" unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end
    def quantities(value, concurrency: false)
      value = B.data(value)
      exact!(value, concurrency ? RESOURCES + ["concurrency"] : RESOURCES)
      raise K::InvalidContract, "bounded nonnegative integer quantities required" unless value.values.all? { |n| n.is_a?(Integer) && n.between?(0, MAX_INTEGER) }
      value
    end
  end
end
