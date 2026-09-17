# frozen_string_literal: true

module Agentkit
  class ActionOutboxRecord < ApplicationRecord
    self.table_name = "agentkit_action_outboxes"
    belongs_to :proposal, class_name: "Agentkit::ActionProposalRecord"
  end
end
