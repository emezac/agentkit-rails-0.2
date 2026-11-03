# frozen_string_literal: true

module Agentkit
  class RoutineOccurrenceRecord < ApplicationRecord
    self.table_name = "agentkit_routine_occurrences"

    belongs_to :routine, class_name: "Agentkit::RoutineRecord"
    validates :status, inclusion: { in: %w[pending dispatching dispatched failed] }
  end
end
