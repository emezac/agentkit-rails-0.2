# frozen_string_literal: true

module Agentkit
  class MemoryProposalRecord < ApplicationRecord
    self.table_name = "agentkit_memory_proposals"

    include Agentkit::TenantAssociations

    has_many :review_events, class_name: "Agentkit::MemoryReviewEventRecord",
                             foreign_key: :proposal_id, dependent: :restrict_with_error

    validates :content, :tenant_key, presence: true
    validates :status, inclusion: { in: %w[pending approved rejected undone] }
  end
end
