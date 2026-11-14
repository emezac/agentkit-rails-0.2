# frozen_string_literal: true

module Agentkit
  class UnattendedRunRecord < ApplicationRecord
    self.table_name = "agentkit_unattended_runs"
  end
end
