# frozen_string_literal: true

module Agentkit
  class ActionProposalRecord < ApplicationRecord
    self.table_name = "agentkit_action_proposals"
    has_one :decision, class_name: "Agentkit::ActionDecisionRecord", foreign_key: :proposal_id
    has_many :execution_attempts, class_name: "Agentkit::ExecutionAttemptRecord", foreign_key: :proposal_id
    has_many :outcomes, class_name: "Agentkit::ActionOutcomeRecord", foreign_key: :proposal_id
    has_one :outbox, class_name: "Agentkit::ActionOutboxRecord", foreign_key: :proposal_id
  end
end
