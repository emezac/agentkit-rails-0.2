# frozen_string_literal: true
module Agentkit
  class SharedBudgetRecord < ApplicationRecord
    self.table_name = "agentkit_shared_budgets"
  end
end
