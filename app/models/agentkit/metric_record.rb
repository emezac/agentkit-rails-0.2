# frozen_string_literal: true

module Agentkit
  # agentkit_metrics — permanent rollups. Raw events expire; these do not, so
  # the factory keeps a long baseline to compare against.
  class MetricRecord < ApplicationRecord
    self.table_name = "agentkit_metrics"
  end
end
