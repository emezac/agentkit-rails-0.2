# frozen_string_literal: true

module Agentkit
  class FindingRecord < ApplicationRecord
    self.table_name = "agentkit_findings"

    scope :open, -> { where(status: "open") }
    scope :by_severity, -> { order(Arel.sql("array_position(ARRAY['high','medium','low'], severity)")) }
  end
end
