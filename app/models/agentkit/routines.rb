# frozen_string_literal: true

module Agentkit
  # Tenant-scoped schedules for registered Flows. A routine never executes
  # arbitrary class names or bypasses a Flow's human gates.
  module Routines
    module_function

    def create!(name:, flow_name:, schedule_kind:, time_zone:, input: {},
                at: nil, interval_seconds: nil, hour: nil, minute: nil, context: nil)
      ctx = context || Agentkit::Context.resolve
      scope = Agentkit::Scope.resolve(context: ctx)
      raise Agentkit::ConfigurationError, "routine requires an authenticated principal" if ctx.principal.to_s.empty?

      now = Time.current
      kind = schedule_kind.to_s
      raise ArgumentError, "input must be a JSON object" unless input.is_a?(Hash)
      raise ArgumentError, "one-time routine requires a future at" if kind == "once" && (at.nil? || at <= now)
      next_at = case kind
                when "once" then at&.to_time
                when "interval" then now + interval_seconds.to_i
                when "daily" then next_daily(now, time_zone, hour, minute)
                end
      Agentkit::RoutineRecord.create!(
        name: name, flow_name: flow_name, schedule_kind: kind, time_zone: time_zone,
        input: input, interval_seconds: interval_seconds, hour: hour, minute: minute,
        next_run_at: next_at, tenant_key: scope.tenant_key || "__global__",
        account_id: scope.account_id, user_id: ctx.user.respond_to?(:id) ? ctx.user.id : nil
      )
    end

    # A single cron entry calls this every minute. Duplicate ticks are safe:
    # row locks and the occurrence uniqueness constraint decide the winner.
    def tick!(at: Time.current, limit: 100)
      ids = []
      Agentkit::RoutineRecord.transaction do
        Agentkit::RoutineRecord.due(at).order(:next_run_at, :id).limit(limit)
                               .lock("FOR UPDATE SKIP LOCKED").each do |routine|
          due_at = routine.next_run_at
          occurrence = routine.occurrences.create!(
            tenant_key: routine.tenant_key, account_id: routine.account_id,
            scheduled_for: due_at
          )
          next_at = case routine.schedule_kind
                    when "once" then nil
                    when "interval" then at + routine.interval_seconds
                    when "daily" then next_daily(at, routine.time_zone, routine.hour, routine.minute)
                    end
          routine.update!(next_run_at: next_at, last_run_at: due_at,
                          status: routine.schedule_kind == "once" ? "paused" : "active")
          ids << occurrence.id
        end
      end
      # Re-enqueue pending receipts if the queue was unavailable after a tick.
      pending = Agentkit::RoutineOccurrenceRecord.where(status: "pending")
                                                 .order(:id).limit(limit).pluck(:id)
      (ids | pending).each { |id| Agentkit::RoutineDispatchJob.perform_later(id) }
      ids.size
    end

    def dispatch!(occurrence_id)
      occurrence = Agentkit::RoutineOccurrenceRecord.find(occurrence_id)
      claimed = Agentkit::RoutineOccurrenceRecord.where(id: occurrence.id, status: "pending")
                                                 .update_all(status: "dispatching", updated_at: Time.current)
      return nil if claimed.zero?

      routine = occurrence.routine
      flow = Agentkit::Flow::Registry.find(routine.flow_name)
      raise Agentkit::FlowError, "Flow #{routine.flow_name} is not loaded" unless flow.is_a?(Class) && Agentkit::Flow::Registry.all.include?(flow)

      context = Agentkit::Context.new(
        user: routine.user_id, account: routine.account_id,
        tenant_key: routine.tenant_key == "__global__" ? nil : routine.tenant_key,
        principal: "routine:#{routine.id}",
        metadata: { routine_id: routine.id, routine_occurrence_id: occurrence.id }
      )
      run = Agentkit.with_context(context) { flow.perform_later(context: context, **routine.input.symbolize_keys) }
      occurrence.update!(status: "dispatched", flow_run_id: run.run_id)
      run
    rescue StandardError => e
      occurrence&.update!(status: "failed", error: "#{e.class}: #{e.message}".truncate(1000)) if claimed&.positive?
      raise
    end

    # Rails/ActiveSupport applies IANA time-zone transitions. A nonexistent
    # spring-forward wall time is skipped; a repeated fall-back time fires once.
    def next_daily(after, zone_name, hour, minute)
      zone = ActiveSupport::TimeZone[zone_name]
      raise ArgumentError, "invalid time zone" unless zone

      local = after.in_time_zone(zone)
      (0..370).each do |offset|
        day = local.to_date + offset
        candidate = zone.local(day.year, day.month, day.day, hour.to_i, minute.to_i)
        return candidate if candidate > after && candidate.hour == hour.to_i && candidate.min == minute.to_i
      end
      raise ArgumentError, "could not schedule next local day"
    end
  end
end
