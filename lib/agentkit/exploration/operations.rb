# frozen_string_literal: true

module Agentkit
  module Exploration
    ReadinessReport = Struct.new(:ready, :generated_at, :checks, :warnings, :operations,
                                 keyword_init: true) do
      def ready? = ready
      def to_h
        { ready: ready, generated_at: generated_at, checks: checks,
          warnings: warnings, operations: operations&.to_h }
      end
    end

    MaintenanceReport = Struct.new(:dry_run, :generated_at, :quota_cutoff, :pruned,
                                   :readiness, keyword_init: true) do
      def dry_run? = dry_run
      def to_h
        { dry_run: dry_run, generated_at: generated_at, quota_cutoff: quota_cutoff,
          pruned: pruned, readiness: readiness.to_h }
      end
    end

    class << self
      # One stable preflight for deploys, probes and the operator dashboard.
      # Warnings describe work waiting for an operator; checks describe whether
      # the configured execution/governance path can operate safely.
      def readiness(scope: nil)
        resolved_scope = Scope.resolve(scope)
        snapshot = operations(scope: resolved_scope)
        ar_requested = Agentkit.config.exploration.store.to_s == "active_record"
        distributed = Agentkit.config.exploration.execution.to_s == "distributed"
        checks = {
          configuration: configuration_valid?,
          audit_enabled: Agentkit.config.audit.enabled == true,
          world_store: !ar_requested || exploration_schema_ready?,
          promotion_governance: !ar_requested || governance_schema_ready?,
          dispatcher: !distributed || dispatcher.respond_to?(:call)
        }.freeze
        warnings = []
        warnings << "adaptive exploration is disabled" unless Agentkit.config.exploration.enabled
        queued = snapshot.world_counts.fetch("queued", 0)
        running = snapshot.world_counts.fetch("running", 0)
        unknown = snapshot.attempt_counts.fetch("execution_unknown", 0)
        pending = Governance.reviews(scope: resolved_scope, status: :pending, limit: 200).size
        warnings << "#{queued} queued exploration worlds" if queued.positive?
        warnings << "#{running} running exploration worlds" if running.positive?
        warnings << "#{unknown} exploration attempts require reconciliation" if unknown.positive?
        warnings << "#{pending} promotion reviews await a human decision" if pending.positive?
        ReadinessReport.new(
          ready: checks.values.all?, generated_at: Time.now.utc,
          checks: checks, warnings: warnings.freeze, operations: snapshot
        ).freeze
      rescue StandardError => e
        ReadinessReport.new(
          ready: false, generated_at: Time.now.utc,
          checks: { probe: false }.freeze,
          warnings: ["readiness probe failed: #{e.class}"].freeze, operations: nil
        ).freeze
      end

      # Retention is explicit and defaults to dry-run. Exploration worlds,
      # evidence dossiers, bindings and audit entries are never pruned here.
      def maintain!(scope: nil, dry_run: true, at: Time.now.utc)
        resolved_scope = Scope.resolve(scope)
        cutoff = at.utc.to_date - Agentkit.config.exploration.quota_retention_days.to_i
        pruned = dry_run ? { usages: 0, reservations: 0, before: cutoff } :
                           Quota.prune!(before: cutoff, scope: resolved_scope)
        MaintenanceReport.new(
          dry_run: !!dry_run, generated_at: Time.now.utc, quota_cutoff: cutoff,
          pruned: pruned.freeze, readiness: readiness(scope: resolved_scope)
        ).freeze
      end

      private

      def configuration_valid?
        Agentkit.config.validate.empty?
      rescue StandardError
        false
      end

      def exploration_schema_ready?
        defined?(Agentkit::ExplorationWorldRecord) &&
          Agentkit::ExplorationWorldRecord.table_exists? &&
          Agentkit::ExplorationAttemptRecord.table_exists? &&
          Agentkit::ExplorationQuotaUsageRecord.table_exists? &&
          Agentkit::ExplorationQuotaReservationRecord.table_exists?
      rescue StandardError
        false
      end

      def governance_schema_ready?
        defined?(Agentkit::ExplorationReviewRecord) &&
          Agentkit::ExplorationReviewRecord.table_exists? &&
          Agentkit::ExplorationPolicyBindingRecord.table_exists?
      rescue StandardError
        false
      end
    end
  end
end
