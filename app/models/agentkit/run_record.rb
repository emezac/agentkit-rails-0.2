# frozen_string_literal: true

module Agentkit
  class RunRecord < ApplicationRecord
    self.table_name = "agentkit_runs"

    include Agentkit::TenantAssociations

    has_many :steps, class_name: "Agentkit::RunStepRecord",
                     foreign_key: :run_id, dependent: :delete_all, inverse_of: :run

    scope :active,   -> { where(status: %w[pending running waiting_join waiting_human]) }
    scope :waiting,  -> { where(status: %w[waiting_join waiting_human]) }
    scope :recent,   -> { order(created_at: :desc) }
  end
end
