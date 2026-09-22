# frozen_string_literal: true

require "date"

module Agentkit
  module Exploration
    # Atomic, idempotent admission accounting for online exploration. A quota
    # reservation is identified by the durable world/round key, so duplicate
    # job delivery never consumes capacity twice.
    module Quota
      Snapshot = Struct.new(:resource, :period_start, :used, :limit, :remaining,
                            keyword_init: true) do
        def unlimited? = limit.nil?
        def to_h = members.to_h { |member| [member, public_send(member)] }
      end

      class MemoryStore
        def initialize
          @usage = Hash.new(0)
          @reservations = {}
          @mutex = Mutex.new
        end

        def reserve!(resource:, amount:, limit:, reservation_key:, scope:, period_start:)
          key = usage_key(resource, scope, period_start)
          reservation = [scope.tenant_key || "__global__", scope.account_id || 0,
                         resource.to_s, reservation_key.to_s]
          @mutex.synchronize do
            return @usage[key] if @reservations.key?(reservation)

            proposed = @usage[key] + amount
            raise_exceeded!(resource, limit, proposed) if limit && proposed > limit

            @usage[key] = proposed
            @reservations[reservation] = { amount: amount, period_start: period_start }
            proposed
          end
        end

        def usage(resource:, scope:, period_start:)
          @mutex.synchronize { @usage[usage_key(resource, scope, period_start)] }
        end

        def clear
          @mutex.synchronize { @usage.clear; @reservations.clear }
        end

        def prune!(before:, scope:)
          @mutex.synchronize do
            usage_before = @usage.size
            reservations_before = @reservations.size
            @usage.delete_if do |key, _|
              same_scope_key?(key, scope) && key.fetch(3) < before
            end
            @reservations.delete_if do |key, value|
              same_scope_key?(key, scope) && value.fetch(:period_start) < before
            end
            { usages: usage_before - @usage.size,
              reservations: reservations_before - @reservations.size }
          end
        end

        private

        def usage_key(resource, scope, period_start)
          [scope.tenant_key || "__global__", scope.account_id, resource.to_s, period_start]
        end

        def same_scope_key?(key, scope)
          key.fetch(0).to_s == (scope.tenant_key || "__global__").to_s &&
            key.fetch(1).to_i == (scope.account_id || 0).to_i
        end

        def raise_exceeded!(resource, limit, used)
          raise ExplorationQuotaExceeded.new(resource: "exploration_#{resource}", limit: limit, used: used)
        end
      end

      class ActiveRecordStore
        def reserve!(resource:, amount:, limit:, reservation_key:, scope:, period_start:)
          tenant_key = scope.tenant_key || "__global__"
          Agentkit::ExplorationQuotaUsageRecord.transaction(requires_new: true) do
            usage = find_or_create_usage!(tenant_key, scope.account_id, resource, period_start)
            usage.lock!
            existing = Agentkit::ExplorationQuotaReservationRecord.find_by(
              tenant_key: tenant_key, account_id: account_key(scope), resource: resource.to_s,
              reservation_key: reservation_key.to_s
            )
            if existing
              usage.used
            else
              proposed = usage.used + amount
              if limit && proposed > limit
                raise ExplorationQuotaExceeded.new(
                  resource: "exploration_#{resource}", limit: limit, used: proposed
                )
              end

              usage.update!(used: proposed)
              Agentkit::ExplorationQuotaReservationRecord.create!(
                tenant_key: tenant_key, account_id: account_key(scope),
                resource: resource.to_s, reservation_key: reservation_key.to_s,
                amount: amount, period_start: period_start
              )
              proposed
            end
          end
        rescue ::ActiveRecord::RecordNotUnique
          retry
        end

        def usage(resource:, scope:, period_start:)
          relation = Agentkit::ExplorationQuotaUsageRecord.where(
            tenant_key: scope.tenant_key || "__global__",
            resource: resource.to_s, period_start: period_start
          )
          relation = relation.where(account_id: account_key(scope))
          relation.pick(:used).to_i
        end

        def clear
          Agentkit::ExplorationQuotaReservationRecord.delete_all
          Agentkit::ExplorationQuotaUsageRecord.delete_all
        end

        def prune!(before:, scope:)
          filters = { tenant_key: scope.tenant_key || "__global__",
                      account_id: account_key(scope) }
          Agentkit::ExplorationQuotaReservationRecord.transaction do
            reservations = Agentkit::ExplorationQuotaReservationRecord
                           .where(filters).where(period_start: ...before).delete_all
            usages = Agentkit::ExplorationQuotaUsageRecord
                     .where(filters).where(period_start: ...before).delete_all
            { usages: usages, reservations: reservations }
          end
        end

        private

        def find_or_create_usage!(tenant_key, account_id, resource, period_start)
          Agentkit::ExplorationQuotaUsageRecord.create_or_find_by!(
            tenant_key: tenant_key, account_id: account_id || 0,
            resource: resource.to_s, period_start: period_start
          ) { |row| row.used = 0 }
        end

        def account_key(scope) = scope.account_id || 0
      end

      class << self
        attr_writer :store

        def reserve!(resource:, amount:, reservation_key:, scope: Scope.resolve, at: Time.now.utc)
          resource = normalize_resource(resource)
          amount = Integer(amount)
          raise ConfigurationError, "exploration quota amount must be positive" unless amount.positive?

          limit = limit_for(resource, scope)
          period_start = at.utc.to_date
          used = store.reserve!(resource: resource, amount: amount, limit: limit,
                                reservation_key: reservation_key, scope: scope,
                                period_start: period_start)
          emit(resource, amount, used, limit)
          snapshot_for(resource, scope: scope, at: at, used: used, limit: limit)
        rescue ExplorationQuotaExceeded => e
          Telemetry.emit("exploration.quota.exceeded",
                         dims: { resource: resource.to_s },
                         measures: { used: e.used.to_i, limit: e.limit.to_i })
          raise
        rescue ArgumentError, TypeError
          raise ConfigurationError, "exploration quota amount must be a positive integer"
        end

        def snapshots(scope: Scope.resolve, at: Time.now.utc)
          %i[worlds attempts].to_h do |resource|
            [resource, snapshot_for(resource, scope: scope, at: at)]
          end
        end

        def prune!(before:, scope: nil)
          cutoff = before.respond_to?(:to_date) ? before.to_date : Date.parse(before.to_s)
          resolved_scope = Scope.resolve(scope)
          result = store.prune!(before: cutoff, scope: resolved_scope)
          Telemetry.emit("exploration.quota.pruned", dims: {},
                         measures: { usages: result.fetch(:usages),
                                     reservations: result.fetch(:reservations) })
          result.merge(before: cutoff)
        rescue ArgumentError, TypeError, Date::Error
          raise ConfigurationError, "exploration quota retention cutoff is invalid"
        end

        def limit_for(resource, scope)
          key = resource == :worlds ? :daily_world_limit : :daily_attempt_limit
          configured = Agentkit.config.exploration.public_send(key)
          resolver = Agentkit.config.exploration.quota_resolver
          overrides = resolver.respond_to?(:call) ? resolver.call(scope) : nil
          unless overrides.nil? || overrides.respond_to?(:to_h)
            raise ConfigurationError, "exploration quota_resolver must return a hash"
          end
          value = (overrides || {}).to_h.transform_keys(&:to_sym).fetch(key, configured)
          return nil if value.nil?

          limit = Integer(value)
          raise ConfigurationError, "exploration #{key} must be non-negative" if limit.negative?

          limit
        rescue ArgumentError, TypeError
          raise ConfigurationError, "exploration #{key} must be a non-negative integer or nil"
        end

        def reset!
          @store = nil
          self
        end

        def store
          return @store if @store
          if Agentkit.config.exploration.store.to_s == "active_record" && active_record_available?
            ActiveRecordStore.new
          else
            @store = MemoryStore.new
          end
        end

        private

        def snapshot_for(resource, scope:, at:, used: nil, limit: nil)
          period_start = at.utc.to_date
          limit = limit_for(resource, scope) if limit.nil?
          used ||= store.usage(resource: resource, scope: scope, period_start: period_start)
          Snapshot.new(resource: resource.to_s, period_start: period_start,
                       used: used, limit: limit,
                       remaining: limit.nil? ? nil : [limit - used, 0].max).freeze
        end

        def normalize_resource(resource)
          value = resource.to_sym
          return value if %i[worlds attempts].include?(value)

          raise ConfigurationError, "unknown exploration quota resource #{resource.inspect}"
        end

        def active_record_available?
          defined?(Agentkit::ExplorationQuotaUsageRecord) &&
            Agentkit::ExplorationQuotaUsageRecord.respond_to?(:table_exists?) &&
            Agentkit::ExplorationQuotaUsageRecord.table_exists?
        rescue StandardError
          false
        end

        def emit(resource, amount, used, limit)
          Telemetry.emit("exploration.quota.reserved",
                         dims: { resource: resource.to_s, limited: !limit.nil? },
                         measures: { amount: amount, used: used, limit: limit.to_i })
        end
      end
    end
  end
end
