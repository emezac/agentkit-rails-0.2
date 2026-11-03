# frozen_string_literal: true

module Agentkit
  class MemoryReviewEventRecord < ApplicationRecord
    self.table_name = "agentkit_memory_review_events"

    belongs_to :proposal, class_name: "Agentkit::MemoryProposalRecord"

    def readonly?
      persisted? || super
    end

    before_destroy { throw :abort }
  end
end
