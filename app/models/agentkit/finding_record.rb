# frozen_string_literal: true

require "digest"

module Agentkit
  class FindingRecord < ApplicationRecord
    self.table_name = "agentkit_findings"

    scope :open, -> { where(status: "open") }
    scope :active, -> { where(status: Agentkit::Factory::ACTIVE_FINDING_STATUSES) }
    scope :by_severity, -> { order(Arel.sql("array_position(ARRAY['high','medium','low'], severity)")) }

    before_validation :populate_factory_identity, on: :create

    validates :fingerprint, presence: true, if: -> { has_attribute?(:fingerprint) }
    validates :status, inclusion: { in: Agentkit::Factory::FINDING_STATUSES }

    private

    def populate_factory_identity
      now = Time.current
      self.fingerprint ||= Digest::SHA256.hexdigest(
        [ detector, subject ].map { |value| value.to_s.strip.downcase }.join(":")
      ) if has_attribute?(:fingerprint)
      self.first_seen_at ||= now if has_attribute?(:first_seen_at)
      self.last_seen_at ||= now if has_attribute?(:last_seen_at)
    end
  end
end
