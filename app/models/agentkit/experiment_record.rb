# frozen_string_literal: true

module Agentkit
  class ExperimentRecord < ApplicationRecord
    self.table_name = "agentkit_experiments"

    scope :running, -> { where(status: "running") }
  end
end
