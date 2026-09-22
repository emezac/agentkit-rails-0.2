# frozen_string_literal: true

module Agentkit
  class ExplorationQuotaUsageRecord < ApplicationRecord
    self.table_name = "agentkit_exploration_quota_usages"

    validates :tenant_key, :resource, :period_start, presence: true
    validates :resource, inclusion: { in: %w[worlds attempts] }
    validates :used, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
