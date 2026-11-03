# frozen_string_literal: true

module Agentkit
  class RoutineTickJob < ApplicationJob
    def perform
      Agentkit::Routines.tick!
    end
  end
end
