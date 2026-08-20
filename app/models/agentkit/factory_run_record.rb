# frozen_string_literal: true

module Agentkit
  class FactoryRunRecord < ApplicationRecord
    self.table_name = "agentkit_factory_runs"

    scope :recent_first, -> { order(started_at: :desc, id: :desc) }
    scope :failed, -> { where(status: "failed") }

    validates :tenant_key, presence: true

    def finish!(status:, **counts)
      update!(counts.merge(status: status.to_s, finished_at: Time.current))
    end
  end
end
