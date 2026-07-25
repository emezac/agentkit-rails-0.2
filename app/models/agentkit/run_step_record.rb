# frozen_string_literal: true

module Agentkit
  class RunStepRecord < ApplicationRecord
    self.table_name = "agentkit_run_steps"

    belongs_to :run, class_name: "Agentkit::RunRecord", inverse_of: :steps
    belongs_to :parent_step, class_name: "Agentkit::RunStepRecord", optional: true

    scope :barriers, -> { where(kind: %w[parallel map]) }
    scope :open_barriers, -> { barriers.where("pending_count > 0") }
  end
end
