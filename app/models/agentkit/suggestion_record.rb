# frozen_string_literal: true

module Agentkit
  class SuggestionRecord < ApplicationRecord
    self.table_name = "agentkit_suggestions"

    include Agentkit::TenantAssociations

    belongs_to :suggestable, polymorphic: true, optional: true
    belongs_to :experiment, class_name: "Agentkit::ExperimentRecord", optional: true
    has_many :decisions, class_name: "Agentkit::DecisionRecord",
                         foreign_key: :suggestion_id, dependent: :destroy, inverse_of: :suggestion

    scope :pending,  -> { where(status: "pending") }
    scope :resolved, -> { where(status: %w[accepted rejected auto_applied expired]) }
    scope :for_gate, ->(key) { where(gate_key: key) }
  end
end
