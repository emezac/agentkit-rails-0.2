# frozen_string_literal: true

module Agentkit
  class ActionDecisionRecord < ApplicationRecord
    self.table_name = "agentkit_action_decisions"
    belongs_to :proposal, class_name: "Agentkit::ActionProposalRecord"
  end
end
