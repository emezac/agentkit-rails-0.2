# frozen_string_literal: true

module Agentkit
  class ExplorationAttemptRecord < ApplicationRecord
    self.table_name = "agentkit_exploration_attempts"

    validates :attempt_id, :world_id, :tenant_key, :parent_node_id,
              :idempotency_key, :status, presence: true
    validates :round_number, :position, numericality: { greater_than_or_equal_to: 0 }
    validates :status, inclusion: { in: %w[pending running completed failed execution_unknown] }
  end
end
