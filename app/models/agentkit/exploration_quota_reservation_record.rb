# frozen_string_literal: true

module Agentkit
  class ExplorationQuotaReservationRecord < ApplicationRecord
    self.table_name = "agentkit_exploration_quota_reservations"

    validates :tenant_key, :resource, :reservation_key, :period_start, presence: true
    validates :resource, inclusion: { in: %w[worlds attempts] }
    validates :amount, numericality: { only_integer: true, greater_than: 0 }
  end
end
