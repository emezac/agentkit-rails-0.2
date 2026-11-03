# frozen_string_literal: true

module Agentkit
  class RoutinesController < ApplicationController
    def index
      @routines = scoped_routines.order(created_at: :desc).limit(100)
      render template: "agentkit/routines_index"
    end

    def create
      input = JSON.parse(params[:input_json].presence || "{}")
      raise ArgumentError, "input must be a JSON object" unless input.is_a?(Hash)

      Agentkit::Routines.create!(
        name: params.require(:name), flow_name: params.require(:flow_name),
        schedule_kind: params.require(:schedule_kind), time_zone: params.require(:time_zone),
        input: input, at: params[:at].present? ? Time.iso8601(params[:at]) : nil,
        interval_seconds: params[:interval_seconds].presence&.to_i,
        hour: params[:hour].presence&.to_i, minute: params[:minute].presence&.to_i,
        context: agentkit_context
      )
      redirect_to routines_path, notice: "Rutina creada"
    rescue ActiveRecord::RecordInvalid, JSON::ParserError, ArgumentError, Agentkit::ConfigurationError => e
      redirect_to routines_path, alert: e.message
    end

    def pause
      scoped_routines.find(params[:id]).update!(status: "paused")
      redirect_to routines_path, notice: "Rutina pausada"
    end

    def resume
      routine = scoped_routines.find(params[:id])
      next_at = if routine.next_run_at.nil?
                  Agentkit::Routines.next_daily(Time.current, routine.time_zone, routine.hour, routine.minute) if routine.schedule_kind == "daily"
                else
                  routine.next_run_at
                end
      next_at ||= Time.current + routine.interval_seconds if routine.schedule_kind == "interval"
      raise ArgumentError, "a one-time routine cannot be resumed" if next_at.nil?

      routine.update!(status: "active", next_run_at: next_at)
      redirect_to routines_path, notice: "Rutina reanudada"
    rescue ArgumentError => e
      redirect_to routines_path, alert: e.message
    end

    private

    def scoped_routines
      scope = Agentkit::Scope.resolve(context: agentkit_context)
      Agentkit::RoutineRecord.where(tenant_key: scope.tenant_key || "__global__", account_id: scope.account_id)
    end
  end
end
