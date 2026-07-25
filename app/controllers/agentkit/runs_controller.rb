# frozen_string_literal: true

module Agentkit
  # Flow dashboard. Seeing the graph execute is also the demo: it sells the
  # product better than a log file.
  class RunsController < ApplicationController
    def index
      @status = params[:status].presence
      @runs   = Agentkit::RunRecord.then { |s| @status ? s.where(status: @status) : s }
                                   .recent.limit(100)
      @counts = Agentkit::RunRecord.group(:status).count
    end

    def show
      @run   = Agentkit::RunRecord.find(params[:id])
      @steps = @run.steps.order(:position, :id)
      @audit = Agentkit::Audit.entries(run_id: @run.run_id)
    end

    def retry
      run  = Agentkit::RunRecord.find(params[:id])
      flow = Agentkit::Flow::Registry.find(run.flow_name)
      return redirect_to(runs_path, alert: "Flow #{run.flow_name} no está cargado") if flow.nil?

      flow.resume(run.run_id)
      redirect_to run_path(run), notice: "Run reanudado"
    end
  end
end
