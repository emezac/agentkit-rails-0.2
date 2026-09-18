# frozen_string_literal: true

module Agentkit
  class ExplorationWorldRecord < ApplicationRecord
    self.table_name = "agentkit_exploration_worlds"

    validates :world_id, :tenant_key, :objective_digest, :policy_name, :policy_version,
              :policy_digest, :evaluator_digest, :status, :stop_reason, presence: true
    validates :rounds, :node_count, numericality: { greater_than_or_equal_to: 0 }
  end
end
