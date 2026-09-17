# frozen_string_literal: true

module Agentkit
  # Operational invariants over the durable control plane. Findings use stable
  # fingerprints, so repeated scans update one issue instead of creating noise.
  module Watchtower
    Issue = Struct.new(:id, :tenant_key, :fingerprint, :detector, :severity,
                       :status, :subject_type, :subject_id, :evidence,
                       :first_seen_at, :last_seen_at, :resolved_at,
                       keyword_init: true)

    class << self
      attr_writer :store

      def store
        @store ||= if Agentkit.config.watchtower.store.to_sym == :active_record &&
                      defined?(Agentkit::WatchtowerIssueRecord)
                     ActiveRecordStore.new
                   else
                     InMemory.new
                   end
      end

      def reset!
        @store = nil
      end

      def scan!(now: Time.now, scope: nil)
        return [] unless Agentkit.config.watchtower.enabled

        findings = lifecycle_findings(now, scope) + identity_findings(scope) +
                   audit_findings(scope) + flow_findings(now, scope) +
                   telemetry_findings(now, scope) + adapter_findings(scope)
        fingerprints = findings.map(&:fingerprint)
        findings.each { |issue| store.upsert(issue) }
        store.resolve_absent!(fingerprints, scope: scope, now: now)
        Telemetry.emit("watchtower.scan", measures: { findings: findings.size })
        findings
      end

      def issues(scope: nil, status: nil) = store.issues(scope: scope, status: status)

      private

      def lifecycle_findings(now, scope)
        Actions.all(scope: scope).filter_map do |proposal|
          age = now - proposal.updated_at
          detector, severity = case proposal.status
                               when "approved"
                                 ["approved_without_execution", "high"] if age > Agentkit.config.actions.approved_without_job_after
                               when "executing"
                                 ["stale_execution", "critical"] if age > Agentkit.config.actions.execution_stale_after
                               when "execution_unknown"
                                 ["unreconciled_external_effect", "critical"] if age > Agentkit.config.actions.execution_stale_after
                               end
          next unless detector

          issue(detector, severity, proposal,
                age_seconds: age.round, action_type: proposal.action_type,
                status: proposal.status)
        end
      end

      def identity_findings(scope)
        Actions.all(scope: scope).filter_map do |proposal|
          missing = []
          missing << "tenant_key" if proposal.tenant_key.to_s.empty?
          missing << "requester_principal_id" if proposal.requester_principal_id.to_s.empty?
          issue("missing_security_context", "critical", proposal, missing: missing) if missing.any?
        end
      end

      def audit_findings(scope)
        tenants = Actions.all(scope: scope).map(&:tenant_key).uniq
        tenants.filter_map do |tenant|
          Audit.verify!(tenant_key: tenant)
          nil
        rescue AuditIntegrityError => e
          subject = Struct.new(:public_id, :tenant_key).new(tenant, tenant)
          issue("audit_integrity_failure", "critical", subject, error_class: e.class.name)
        end
      end

      def flow_findings(now, scope)
        return [] unless defined?(Agentkit::RunRecord) && Agentkit::RunRecord.table_exists?

        relation = Agentkit::RunRecord.where(status: "waiting_join")
        tenant = scope.respond_to?(:tenant_key) ? scope.tenant_key : scope&.fetch(:tenant_key, nil)
        relation = relation.where(tenant_key: tenant) if tenant
        relation.where(updated_at: ...(now - Agentkit.config.watchtower.join_stale_after)).map do |run|
          issue("stale_flow_join", "high", run,
                status: run.status, age_seconds: (now - run.updated_at).round)
        end
      rescue StandardError
        []
      end

      def telemetry_findings(now, scope)
        tenant = scope.respond_to?(:tenant_key) ? scope.tenant_key : scope&.fetch(:tenant_key, nil)
        {
          "audit.write_failed" => ["required_audit_failure", "critical"],
          "idempotency.conflict" => ["idempotency_conflict", "high"],
          "memory.budget_exceeded" => ["budget_exceeded", "medium"]
        }.filter_map do |event_name, (detector, severity)|
          events = Telemetry.events(name: event_name, since: now - 3600)
          events = events.select { |event| !tenant || event.dims[:tenant].to_s == tenant.to_s }
          next if events.empty?

          system_issue(detector, severity, tenant || "__global__", count: events.size)
        end
      rescue StandardError
        []
      end

      def adapter_findings(scope)
        return [] unless Agentkit.config.a2a.enabled
        return [] if Agentkit.config.a2a.key_resolver.respond_to?(:call) ||
                     !Agentkit.config.a2a.secret_key.to_s.empty?

        tenant = scope.respond_to?(:tenant_key) ? scope.tenant_key : scope&.fetch(:tenant_key, nil)
        [system_issue("adapter_without_auth_guard", "critical", tenant || "__global__",
                      adapter: "a2a")]
      end

      def system_issue(detector, severity, tenant, evidence)
        subject = Struct.new(:id, :tenant_key).new(detector, tenant)
        issue(detector, severity, subject, evidence)
      end

      def issue(detector, severity, subject, evidence)
        id = subject.respond_to?(:public_id) ? subject.public_id : subject.id
        tenant = subject.respond_to?(:tenant_key) ? subject.tenant_key : "__global__"
        Issue.new(tenant_key: tenant, detector: detector, severity: severity,
                  status: "open", subject_type: subject.class.name,
                  subject_id: id.to_s,
                  fingerprint: Digest::SHA256.hexdigest([tenant, detector, id].join(":")),
                  evidence: Audit.sanitize_payload(evidence), first_seen_at: Time.now,
                  last_seen_at: Time.now)
      end
    end

    class InMemory
      def initialize
        @issues = {}
        @sequence = 0
        @mutex = Mutex.new
      end

      def upsert(issue)
        @mutex.synchronize do
          key = [issue.tenant_key, issue.fingerprint]
          current = @issues[key]
          if current
            current.last_seen_at = Time.now
            current.status = "open"
            current.resolved_at = nil
            current.evidence = issue.evidence
          else
            issue.id = (@sequence += 1)
            @issues[key] = issue
          end
          @issues[key].dup
        end
      end

      def resolve_absent!(active, scope:, now:)
        tenant = scope.respond_to?(:tenant_key) ? scope.tenant_key : scope&.fetch(:tenant_key, nil)
        @mutex.synchronize do
          @issues.values.each do |entry|
            next if tenant && entry.tenant_key != tenant
            next unless entry.status == "open" && !active.include?(entry.fingerprint)

            entry.status = "resolved"
            entry.resolved_at = now
          end
        end
      end

      def issues(scope:, status:)
        tenant = scope.respond_to?(:tenant_key) ? scope.tenant_key : scope&.fetch(:tenant_key, nil)
        @mutex.synchronize do
          @issues.values.select do |entry|
            (!tenant || entry.tenant_key == tenant) && (!status || entry.status == status.to_s)
          end.map(&:dup)
        end
      end
    end

    class ActiveRecordStore
      def upsert(issue)
        row = Agentkit::WatchtowerIssueRecord.find_or_initialize_by(
          tenant_key: issue.tenant_key, fingerprint: issue.fingerprint
        )
        row.assign_attributes(detector: issue.detector, severity: issue.severity,
                              status: "open", subject_type: issue.subject_type,
                              subject_id: issue.subject_id, evidence: issue.evidence,
                              first_seen_at: row.first_seen_at || issue.first_seen_at,
                              last_seen_at: Time.now, resolved_at: nil)
        row.save!
        wrap(row)
      end

      def resolve_absent!(active, scope:, now:)
        relation = relation(scope).where(status: "open")
        relation = relation.where.not(fingerprint: active) if active.any?
        relation.update_all(status: "resolved", resolved_at: now, updated_at: now)
      end

      def issues(scope:, status:)
        rows = relation(scope)
        rows = rows.where(status: status.to_s) if status
        rows.order(severity: :desc, last_seen_at: :desc).map { |row| wrap(row) }
      end

      private

      def relation(scope)
        tenant = scope.respond_to?(:tenant_key) ? scope.tenant_key : scope&.fetch(:tenant_key, nil)
        tenant ? Agentkit::WatchtowerIssueRecord.where(tenant_key: tenant) : Agentkit::WatchtowerIssueRecord.all
      end

      def wrap(row) = Issue.new(**row.attributes.symbolize_keys.slice(*Issue.members))
    end
  end
end
