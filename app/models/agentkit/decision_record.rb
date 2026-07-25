# frozen_string_literal: true

module Agentkit
  # The decision ledger. v0.1 had this data in a JSON blob and read it never;
  # it is the labelled corpus the factory learns from.
  class DecisionRecord < ApplicationRecord
    self.table_name = "agentkit_decisions"

    belongs_to :suggestion, class_name: "Agentkit::SuggestionRecord", optional: true

    # `mode` separates human judgements from advisory timeouts. Quality metrics
    # must only count the former.
    scope :human,    -> { where(mode: "human") }
    scope :accepted, -> { where(decision: %w[accepted edited]) }
    scope :rejected, -> { where(decision: "rejected") }
    scope :since,    ->(t) { where(created_at: t..) }

    def self.acceptance_rate(scope = human)
      total = scope.count
      return nil if total.zero?

      (scope.accepted.count.to_f / total).round(4)
    end
  end
end
