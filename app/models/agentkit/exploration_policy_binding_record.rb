# frozen_string_literal: true

module Agentkit
  class ExplorationPolicyBindingRecord < ApplicationRecord
    self.table_name = "agentkit_exploration_policy_bindings"

    validates :target, :tenant_key, :policy_name, :policy_version,
              :policy_digest, :dossier_id, :applied_at, presence: true
    validates :generation, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  end
end
