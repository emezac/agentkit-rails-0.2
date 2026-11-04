# frozen_string_literal: true

module Agentkit
  class TaskEventRecord < ApplicationRecord
    self.table_name = "agentkit_task_events"
    belongs_to :task_thread, class_name: "Agentkit::TaskThreadRecord"
  end
end
