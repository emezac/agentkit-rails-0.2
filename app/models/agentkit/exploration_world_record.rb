# frozen_string_literal: true

module Agentkit
  class ExplorationWorldRecord < ApplicationRecord
    self.table_name = "agentkit_exploration_worlds"

    validates :world_id, :tenant_key, :objective_digest, :policy_name, :policy_version,
              :policy_digest, :evaluator_digest, :status, presence: true
    validates :stop_reason, :completed_at, presence: true,
                                          unless: -> { %w[queued running].include?(status) }
    validates :rounds, :node_count, numericality: { greater_than_or_equal_to: 0 }
    validates :status, inclusion: { in: %w[queued running completed failed] }
  end
end
