# frozen_string_literal: true

module Agentkit
  class GoldenCaseRecord < ApplicationRecord
    self.table_name = "agentkit_golden_cases"

    scope :for_agent, ->(name) { where(agent_name: name.to_s) }
    scope :reviewed, -> { where(reviewed: true) }

    validates :agent_name, presence: true
    validates :suggestion_id, uniqueness: { scope: :agent_name }, allow_nil: true
  end
end
