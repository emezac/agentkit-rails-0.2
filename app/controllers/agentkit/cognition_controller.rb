# frozen_string_literal: true

module Agentkit
  # On-demand cognition over HTTP — the same entry point cron, the CLI and a
  # flow step use. `dry_run` returns the plan without writing anything.
  class CognitionController < ApplicationController
    def run
      processor = params[:processor].to_sym
      trace = Agentkit::Cognition.run(processor,
                                      dry_run: params[:dry_run].present?,
                                      trigger: :on_demand,
                                      context: agentkit_context,
                                      **cognition_options)

      respond_to do |format|
        format.json { render json: (trace.respond_to?(:to_h) ? trace.to_h : { result: trace }) }
        format.html { redirect_back fallback_location: factory_path, notice: "#{processor} ejecutado" }
      end
    rescue Agentkit::ConfigurationError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def cognition_options
      params.permit(:strategy, :threshold, :min_cluster, :format, :focus)
            .to_h.symbolize_keys
            .transform_values { |v| v.match?(/\A[\d.]+\z/) ? v.to_f : v.to_sym }
    end
  end
end
