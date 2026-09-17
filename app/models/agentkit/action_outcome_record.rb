# frozen_string_literal: true

module Agentkit
  class ActionOutcomeRecord < ApplicationRecord
    self.table_name = "agentkit_action_outcomes"
    belongs_to :proposal, class_name: "Agentkit::ActionProposalRecord"
  end
end
