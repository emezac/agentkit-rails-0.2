# frozen_string_literal: true

module Agentkit
  class RoutineRecord < ApplicationRecord
    self.table_name = "agentkit_routines"

    include Agentkit::TenantAssociations

    has_many :occurrences, class_name: "Agentkit::RoutineOccurrenceRecord",
                           foreign_key: :routine_id, dependent: :restrict_with_error

    validates :name, :flow_name, :tenant_key, :time_zone, presence: true
    validates :schedule_kind, inclusion: { in: %w[once interval daily] }
    validates :status, inclusion: { in: %w[active paused] }
    validates :interval_seconds, numericality: { greater_than_or_equal_to: 60 }, if: -> { schedule_kind == "interval" }
    validates :hour, inclusion: { in: 0..23 }, if: -> { schedule_kind == "daily" }
    validates :minute, inclusion: { in: 0..59 }, if: -> { schedule_kind == "daily" }
    validates :next_run_at, presence: true, if: -> { status == "active" }
    validate :valid_time_zone
    validate :registered_flow

    scope :due, ->(at) { where(status: "active").where("next_run_at <= ?", at) }

    private

    def valid_time_zone
      errors.add(:time_zone, "is invalid") unless ActiveSupport::TimeZone[time_zone]
    end

    def registered_flow
      flow = Agentkit::Flow::Registry.find(flow_name)
      errors.add(:flow_name, "must name a registered Flow") unless flow.is_a?(Class) && Agentkit::Flow::Registry.all.include?(flow)
    end
  end
end
