# frozen_string_literal: true

module Agentkit
  class TelemetryFlushJob < ApplicationJob
    queue_as :agentkit_telemetry

    def perform
      Agentkit::Telemetry.flush!
    end
  end
end
