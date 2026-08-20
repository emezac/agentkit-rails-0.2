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
    validates :tenant_key, presence: true
    validates :level, inclusion: { in: Agentkit::Factory::LEVELS.keys.map(&:to_s) }
    validate :finding_must_share_tenant

    private

    def finding_must_share_tenant
      return if finding.nil? || finding.tenant_key.to_s == tenant_key.to_s

      errors.add(:finding, "must belong to the same tenant")
    end
  end
end
