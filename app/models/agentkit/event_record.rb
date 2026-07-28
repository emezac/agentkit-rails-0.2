# frozen_string_literal: true

module Agentkit
  # agentkit_events — raw telemetry, expired by retention. Rolled up into
  # agentkit_metrics, which is permanent.
  class EventRecord < ApplicationRecord
    self.table_name = "agentkit_events"

    include Agentkit::TenantAssociations

    scope :named,  ->(n) { where(name: n.to_s) }
    scope :since,  ->(t) { where(occurred_at: t..) }
    scope :expired, -> { where(occurred_at: ...Agentkit.config.telemetry.retention_days.days.ago) }

    # Descriptive statistics straight from SQL for the dashboard.
    def self.rollup(name, measure, period: :day, since: 7.days.ago)
      named(name).since(since)
                 .group(Arel.sql("date_trunc('#{period}', occurred_at)"))
                 .pluck(Arel.sql("date_trunc('#{period}', occurred_at), count(*), " \
                                 "avg((measures->>'#{measure}')::float), " \
                                 "percentile_cont(0.5) within group (order by (measures->>'#{measure}')::float), " \
                                 "percentile_cont(0.95) within group (order by (measures->>'#{measure}')::float)"))
                 .map { |row| { period: row[0], n: row[1], mean: row[2], p50: row[3], p95: row[4] } }
    end
  end
end
