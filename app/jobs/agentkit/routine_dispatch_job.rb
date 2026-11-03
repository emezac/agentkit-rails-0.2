# frozen_string_literal: true

module Agentkit
  class RoutineDispatchJob < ApplicationJob
    def perform(occurrence_id)
      Agentkit::Routines.dispatch!(occurrence_id)
    end
  end
end
