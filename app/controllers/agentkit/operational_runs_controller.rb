# frozen_string_literal: true

module Agentkit
  class OperationalRunsController < ApplicationController
    def show
      resolver = Agentkit.config.console.operational_view
      return head(:not_found) unless resolver.respond_to?(:call)

      report = resolver.call(params[:id].to_s, agentkit_context)
      return head(:not_found) if report.nil?
      unless report.is_a?(Hash) && report["schema"] == "agentkit.operational_projection.v1" &&
          report["run_id"] == params[:id].to_s && report["authorizes"] == false
        raise Agentkit::Knowledge::IntegrityError, "invalid operational projection"
      end
      @report = report
    rescue Agentkit::Knowledge::AccessDenied, ActiveRecord::RecordNotFound
      head :not_found
    end
  end
end
