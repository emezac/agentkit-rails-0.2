# frozen_string_literal: true

module Agentkit
  class TaskThreadRecord < ApplicationRecord
    self.table_name = "agentkit_task_threads"
    has_many :events, class_name: "Agentkit::TaskEventRecord", foreign_key: :task_thread_id, dependent: :delete_all
  end
end
