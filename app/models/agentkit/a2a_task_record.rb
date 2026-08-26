# frozen_string_literal: true

module Agentkit
  class A2aTaskRecord < ApplicationRecord
    self.table_name = "agentkit_a2a_tasks"

    validates :tenant_key, :task_id, :payload, presence: true
    validates :task_id, uniqueness: { scope: :tenant_key }
  end
end
