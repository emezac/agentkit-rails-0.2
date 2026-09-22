# frozen_string_literal: true

module Agentkit
  class ExplorationReviewRecord < ApplicationRecord
    self.table_name = "agentkit_exploration_reviews"

    STATUSES = %w[pending approved rejected rolled_back].freeze
    EVIDENCE_FIELDS = %w[
      dossier_id target tenant_key account_id incumbent_name incumbent_version
      incumbent_digest candidate_name candidate_version candidate_digest
      evidence_digest evidence submitted_at
    ].freeze

    validates :dossier_id, :target, :tenant_key, :status, :incumbent_name,
              :incumbent_version, :incumbent_digest, :candidate_name,
              :candidate_version, :candidate_digest, :evidence_digest,
              :submitted_at, presence: true
    validates :status, inclusion: { in: STATUSES }
    validate :immutable_evidence, on: :update

    private

    def immutable_evidence
      changed = changes_to_save.keys & EVIDENCE_FIELDS
      errors.add(:base, "exploration review evidence is immutable") if changed.any?
    end
  end
end
