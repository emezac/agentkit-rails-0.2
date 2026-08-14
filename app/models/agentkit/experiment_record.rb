# frozen_string_literal: true

module Agentkit
  class ExperimentRecord < ApplicationRecord
    self.table_name = "agentkit_experiments"

    scope :running, -> { where(status: "running") }

    belongs_to :finding, class_name: "Agentkit::FindingRecord", optional: true
    has_many :decisions, class_name: "Agentkit::DecisionRecord",
                         foreign_key: :experiment_id, dependent: :nullify,
                         inverse_of: :experiment

    validates :status, inclusion: { in: %w[draft running adopted rolled_back cancelled] }
    validates :level, inclusion: { in: Agentkit::Factory::LEVELS.keys.map(&:to_s) }
  end
end
