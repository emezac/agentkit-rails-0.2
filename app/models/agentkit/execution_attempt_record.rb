# frozen_string_literal: true

module Agentkit
  class ExecutionAttemptRecord < ApplicationRecord
    self.table_name = "agentkit_execution_attempts"
    belongs_to :proposal, class_name: "Agentkit::ActionProposalRecord"
  end
end
