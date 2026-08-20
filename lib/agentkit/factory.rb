# frozen_string_literal: true

require "time"

module Agentkit
  # The software factory: observe → diagnose → hypothesize → experiment →
  # evaluate → adopt/rollback.
  #
  # v0.1 shipped a Fábrica that had zero uses across six projects, for four
  # diagnosable reasons, all corrected here:
  #
  #   1. It measured counts (failures per agent, pending suggestions) and asked
  #      an LLM to invent refactors from them. Findings here are produced by
  #      deterministic detectors with evidence; the LLM only writes the
  #      hypothesis afterwards.
  #   2. It ignored the decision ledger — the labelled data. Detectors read it.
  #   3. It jumped from a metric straight to writing Ruby files on disk
  #      (`CodeGeneration#apply!`). Here interventions are a risk ladder and
  #      level 5 only ever emits a patch for review — never a filesystem write.
  #   4. Its statistics counted advisory timeouts as approvals. The ledger
  #      separates `mode: human` from `mode: auto`.
  module Factory
    Finding = Struct.new(:id, :detector, :severity, :subject, :summary, :evidence,
                         :suggested_level, :created_at, :status, :fingerprint,
                         :occurrence_count, :first_seen_at, :last_seen_at,
                         :resolved_at, :resolved_by, :resolution_reason,
                         :clean_cycles, :tenant_key, :account_id,
                         keyword_init: true) do
      def to_h
        { id: id, detector: detector, severity: severity, subject: subject,
          summary: summary, evidence: evidence, level: suggested_level, status: status,
          fingerprint: fingerprint, occurrence_count: occurrence_count,
          first_seen_at: first_seen_at, last_seen_at: last_seen_at,
          resolved_at: resolved_at, resolved_by: resolved_by,
          resolution_reason: resolution_reason, clean_cycles: clean_cycles }
      end
    end

    Experiment = Struct.new(:id, :name, :level, :target, :control, :variant, :traffic_pct,
                            :bucket_by, :status, :finding_id, :started_at, :finished_at,
                            :last_evaluated_at, :cohort, :results,
                            :tenant_key, :account_id,
                            keyword_init: true)

    GoldenCase = Struct.new(:id, :agent_name, :suggestion_id, :input, :expected,
                            :label, :rejection_code, :frozen, :captured_at,
                            :tenant_key, :account_id,
                            keyword_init: true) do
      def to_h
        members.to_h { |member| [member, public_send(member)] }
      end
    end

    # ─── Detectors ─────────────────────────────────────────────────────────────

    module Detectors
      class << self
        def registry = @registry ||= {}

        def register(name, severity: :medium, level: :n1, &block)
          registry[name.to_sym] = { block: block, severity: severity, level: level }
        end

        def reset!
          @registry = {}
          @last_errors = []
        end

        def last_errors = @last_errors ||= []

        def run_all(window:)
          @last_errors = []
          registry.filter_map do |name, spec|
            evidence = spec[:block].call(Snapshot.new(window: window))
            next if evidence.nil? || evidence == false

            Finding.new(
              id: SecureRandom.uuid, detector: name.to_s, severity: spec[:severity],
              subject: evidence[:subject], summary: evidence[:summary],
              evidence: evidence.except(:subject, :summary),
              suggested_level: spec[:level], created_at: Time.now, status: "open"
            )
          rescue StandardError => e
            last_errors << { detector: name.to_s, error_class: e.class.name,
                             message: e.message }
            Telemetry.emit("factory.detector_failed",
                           dims: { detector: name, error_class: e.class.name },
                           measures: { count: 1 })
            nil
          end
        end
      end
    end

    # Read-only view over telemetry + ledger for the detectors, so a detector is
    # a pure function of measurements.
    class Snapshot
      attr_reader :window, :since, :scope

      def initialize(window:)
        @window = window
        @since  = Time.now - window
        @scope  = Scope.resolve
      end

      def ledger = HITL.ledger

      def agents
        ledger.entries(since: since, scope: scope).map(&:agent_name).compact.uniq
      end

      def acceptance_rate(agent: nil)       = ledger.acceptance_rate(agent: agent, since: since, scope: scope)
      def clean_acceptance_rate(agent: nil) = ledger.clean_acceptance_rate(agent: agent, since: since, scope: scope)
      def ignore_rate(agent: nil)           = ledger.ignore_rate(agent: agent, since: since, scope: scope)
      def rejection_profile(agent: nil)     = ledger.rejection_profile(agent: agent, since: since, scope: scope)
      def cost_per_accepted(agent: nil)     = ledger.cost_per_accepted(agent: agent, since: since, scope: scope)

      def previous(agent: nil, metric: :acceptance_rate)
        prev_since = since - window
        entries = ledger.entries(agent: agent, scope: scope).select { |e| e.created_at.between?(prev_since, since) }
        return nil if entries.empty?

        judged = entries.select { |e| e.mode == "human" }
        return nil if judged.empty?

        case metric
        when :acceptance_rate
          judged.count { |e| %w[accepted edited].include?(e.decision) }.to_f / judged.size
        end
      end

      def llm_stats(measure: :duration_ms, by: nil)
        Telemetry.stats("llm.call", measure: measure, by: by, since: since)
      end

      def events(name)
        Telemetry.events(name: name, since: since).select do |event|
          scope.tenant_key.nil? || event.dims[:tenant].to_s == scope.tenant_key.to_s
        end
      end

      def rate(name, measure) = Telemetry.rate(name, measure: measure, since: since)

      def sum(name, measure)
        events(name).sum { |e| e.measures[measure.to_sym].to_f }
      end

      def count(name) = events(name).size
    end

    # ─── Interventions ─────────────────────────────────────────────────────────

    # The ladder that replaces "metric looks bad → write code to disk".
    # N1 and N2 are fully reversible, which is why they may be automatic.
    LEVELS = {
      n1: { name: "parameters", reversible: true,  auto: true },
      n2: { name: "prompts",    reversible: true,  auto: true },
      n3: { name: "policies",   reversible: true,  auto: false },
      n4: { name: "composition", reversible: true, auto: false },
      n5: { name: "code",       reversible: false, auto: false }
    }.freeze
    ACTIVE_FINDING_STATUSES = %w[open accepted experimenting].freeze
    FINDING_STATUSES = (ACTIVE_FINDING_STATUSES + %w[dismissed resolved]).freeze

    # A host application must explicitly register every reversible N1 action.
    # This is deliberately a registry of narrow adapters rather than a generic
    # "write config" hook: an experiment can only touch a target whose apply,
    # adopt and rollback semantics are known and testable.
    module Interventions
      Adapter = Struct.new(:target, :level, :apply, :adopt, :rollback, keyword_init: true)

      class << self
        def registry = @registry ||= {}

        def register(target, level: :n1, apply:, rollback:, adopt: nil)
          level = level.to_sym
          raise ConfigurationError, "Only reversible N1-N4 interventions can be registered" unless
            %i[n1 n2 n3 n4].include?(level)

          registry[target.to_s] = Adapter.new(
            target: target.to_s, level: level.to_s, apply: apply,
            adopt: adopt || ->(_experiment) {}, rollback: rollback
          )
        end

        def fetch(target)
          registry.fetch(target.to_s) do
            raise ConfigurationError, "No reversible intervention registered for #{target}"
          end
        end

        def reset! = @registry = {}
      end
    end

    module Plans
      class << self
        def registry = @registry ||= {}
        def register(detector, &block) = registry[detector.to_s] = block
        def fetch(detector) = registry[detector.to_s]
        def reset! = @registry = {}
      end
    end

    class << self
      # Persisted when the engine is loaded, in memory otherwise.
      #
      # These were a process-local array. The diagnose cron runs in a worker and
      # the console renders in a web process, so the owner never saw what the
      # cycle found — and whatever it did find vanished on the next deploy.
      # agentkit_findings and agentkit_experiments were dead schema: models,
      # tables, and nothing writing to them.
      def persisted?
        return false if @persistence == :memory
        return true if @persistence == :active_record &&
          defined?(Agentkit::FindingRecord) && Agentkit::FindingRecord.table_exists? &&
          defined?(Agentkit::ExperimentRecord) && Agentkit::ExperimentRecord.table_exists?

        defined?(Agentkit::FindingRecord) && Agentkit::FindingRecord.table_exists? &&
          defined?(Agentkit::ExperimentRecord) && Agentkit::ExperimentRecord.table_exists?
      end

      attr_writer :persistence

      def findings
        return (@findings ||= []).select { |finding| factory_scope.match?(finding) } unless persisted?

        finding_relation.order(created_at: :desc).map { |r| finding_from(r) }
      end

      def experiments
        return (@experiments ||= []).select { |experiment| factory_scope.match?(experiment) } unless persisted?

        experiment_relation.order(created_at: :desc).map { |r| experiment_from(r) }
      end

      def finding_from(row)
        Finding.new(id: row.id.to_s, detector: row.detector, severity: row.severity.to_sym,
                    subject: row.subject, summary: row.summary,
                    evidence: deep_symbolize_keys(row.evidence || {}),
                    suggested_level: row.suggested_level.to_sym, status: row.status,
                    created_at: row.created_at,
                    fingerprint: attribute(row, :fingerprint),
                    occurrence_count: attribute(row, :occurrence_count) || 1,
                    first_seen_at: attribute(row, :first_seen_at) || row.created_at,
                    last_seen_at: attribute(row, :last_seen_at) || row.updated_at,
                    resolved_at: attribute(row, :resolved_at),
                    resolved_by: attribute(row, :resolved_by),
                    resolution_reason: attribute(row, :resolution_reason),
                    clean_cycles: attribute(row, :clean_cycles) || 0,
                    tenant_key: attribute(row, :tenant_key), account_id: attribute(row, :account_id))
      end

      def experiment_from(row)
        Experiment.new(id: row.id.to_s, name: row.name, level: row.level, target: row.target,
                       control: row.control, variant: row.variant, traffic_pct: row.traffic_pct,
                       bucket_by: row.bucket_by, status: row.status,
                       finding_id: row.finding_id&.to_s, started_at: row.started_at,
                       finished_at: row.finished_at,
                       last_evaluated_at: attribute(row, :last_evaluated_at),
                       cohort: attribute(row, :cohort) || {}, results: row.results || {},
                       tenant_key: attribute(row, :tenant_key), account_id: attribute(row, :account_id))
      end

      def golden_sets
        return @golden_sets ||= Hash.new { |h, k| h[k] = [] } unless golden_persisted?

        golden_relation.order(:id).map { |row| golden_case_from(row) }
                                  .group_by(&:agent_name)
                                  .tap { |groups| groups.default_proc = ->(h, k) { h[k] = [] } }
      end

      def golden_case_from(row)
        GoldenCase.new(
          id: row.id.to_s, agent_name: row.agent_name,
          suggestion_id: row.suggestion_id, input: row.input,
          expected: row.expected, label: row.label,
          rejection_code: row.rejection_code, frozen: row.reviewed,
          captured_at: row.created_at, tenant_key: attribute(row, :tenant_key),
          account_id: attribute(row, :account_id)
        )
      end

      def reset!
        @findings    = []
        @experiments = []
        @golden_sets = nil
        @patches     = []
        @golden_runners = {}
        @last_diagnosis = nil
        Detectors.reset!
        Interventions.reset!
        Plans.reset!
        @defaults_installed = false
        install_default_detectors!
        self
      end

      # ─── Observe → Diagnose ──────────────────────────────────────────────────

      def diagnose!(window: 7 * 86_400)
        install_default_detectors! if Detectors.registry.empty?

        firings = Detectors.run_all(window: window)
        created = []

        firings.each do |finding|
          stored, is_new = record_finding(finding)
          next unless is_new

          created << stored
          Telemetry.emit("factory.finding",
                         dims: { detector: finding.detector, severity: finding.severity,
                                 level: finding.suggested_level },
                         measures: { count: 1 })
        end
        auto_resolve_quiet_findings!(
          firings.map { |finding| finding_fingerprint(finding.detector, finding.subject) },
          failed_detectors: Detectors.last_errors.map { |error| error[:detector] }
        )
        Telemetry.emit("factory.diagnosed",
                       measures: { fired: firings.size, created: created.size,
                                   deduplicated: firings.size - created.size })
        @last_diagnosis = { detector_count: Detectors.registry.size, fired_count: firings.size,
                            created_count: created.size,
                            deduplicated_count: firings.size - created.size,
                            errors: Detectors.last_errors }
        created
      end

      def last_diagnosis = @last_diagnosis || {}

      # Convert deterministic findings into bounded, reviewable interventions.
      # A detector has no authority to invent arbitrary changes: the host must
      # register a plan that names an already registered reversible target.
      def suggest_interventions!(selected_findings)
        ensure_intervention_handler!
        Array(selected_findings).filter_map do |finding|
          plan = plan_for(finding)
          next unless plan

          HITL.suggest!(
            type: "factory_intervention",
            title: "Experiment for #{finding.detector}: #{finding.subject}",
            description: finding.summary,
            source_agent: "Agentkit::Factory", priority: finding.severity,
            idempotency_key: "factory:#{finding.fingerprint}:#{plan[:target]}",
            payload: stringify_keys(plan).merge("finding_id" => finding.id)
          )
        end
      end

      def auto_start_interventions!(selected_findings, max_level: :n1)
        ceiling = LEVELS.keys.index(max_level.to_sym) || 0
        Array(selected_findings).filter_map do |finding|
          plan = plan_for(finding)
          next unless plan
          next if (LEVELS.keys.index(plan[:level].to_sym) || LEVELS.size) > ceiling
          next unless LEVELS.fetch(plan[:level].to_sym)[:auto]

          start_plan!(finding, plan)
        end
      end

      def start_intervention_suggestion!(suggestion)
        plan = symbolize_keys(suggestion.payload || {})
        finding = findings.find { |candidate| candidate.id.to_s == plan.delete(:finding_id).to_s }
        raise ConfigurationError, "Factory finding no longer exists" unless finding

        start_plan!(finding, plan)
      end

      def record_finding(finding)
        scope = factory_scope
        finding.tenant_key ||= scope.tenant_key || "__global__"
        finding.account_id ||= scope.account_id
        fingerprint = finding_fingerprint(finding.detector, finding.subject)
        now = Time.now

        unless persisted?
          existing = (@findings ||= []).find do |row|
            row.fingerprint == fingerprint && ACTIVE_FINDING_STATUSES.include?(row.status.to_s)
          end
          if existing
            existing.occurrence_count = existing.occurrence_count.to_i + 1
            existing.last_seen_at = now
            existing.summary = finding.summary
            existing.evidence = finding.evidence || {}
            existing.clean_cycles = 0
            return [existing, false]
          end

          finding.fingerprint = fingerprint
          finding.occurrence_count = 1
          finding.first_seen_at = finding.last_seen_at = now
          finding.clean_cycles = 0
          (@findings ||= []) << finding
          return [finding, true]
        end

        active = finding_relation.where(fingerprint: fingerprint,
                                        status: ACTIVE_FINDING_STATUSES).first
        if active
          active.with_lock do
            active.update!(
              occurrence_count: active.occurrence_count.to_i + 1,
              last_seen_at: now, summary: finding.summary,
              evidence: finding.evidence || {}, clean_cycles: 0
            )
          end
          return [finding_from(active.reload), false]
        end

        recent = finding_relation.where(fingerprint: fingerprint)
                                        .order(last_seen_at: :desc, id: :desc).first
        cooldown = Agentkit.config.factory.finding_cooldown.to_f
        if recent && recent.last_seen_at && now - recent.last_seen_at < cooldown
          recent.update!(last_seen_at: now,
                         occurrence_count: recent.occurrence_count.to_i + 1)
          return [finding_from(recent), false]
        end

        row = Agentkit::FindingRecord.create!(
          detector: finding.detector.to_s, severity: finding.severity.to_s,
          subject: finding.subject, summary: finding.summary,
          evidence: finding.evidence || {}, fingerprint: fingerprint,
          occurrence_count: 1, first_seen_at: now, last_seen_at: now,
          clean_cycles: 0,
          tenant_key: finding.tenant_key, account_id: finding.account_id,
          suggested_level: finding.suggested_level.to_s, status: finding.status || "open"
        )
        [finding_from(row), true]
      rescue ActiveRecord::RecordNotUnique
        active = finding_relation.find_by!(fingerprint: fingerprint,
                                           status: ACTIVE_FINDING_STATUSES)
        active.with_lock do
          active.update!(occurrence_count: active.occurrence_count.to_i + 1,
                         last_seen_at: now, clean_cycles: 0,
                         summary: finding.summary, evidence: finding.evidence || {})
        end
        [finding_from(active.reload), false]
      end

      # What the owner does with one. A finding is resolved by a person, and
      # the record of who decided what is the point of keeping them.
      def resolve_finding!(id, status, actor: nil, reason: nil)
        raise ConfigurationError, "Unknown finding status: #{status}" unless
          FINDING_STATUSES.include?(status.to_s)

        status = status.to_s
        terminal = %w[dismissed resolved].include?(status)

        if persisted?
          row = finding_relation.find_by(id: id)
          raise ConfigurationError, "Finding #{id} not found" unless row

          row.with_lock do
            row.update!(
              status: status,
              resolved_at: terminal ? Time.now : nil,
              resolved_by: actor&.to_s,
              resolution_reason: reason
            )
          end
          found = finding_from(row.reload)
        else
          found = (@findings ||= []).find { |f| f.id.to_s == id.to_s }
          raise ConfigurationError, "Finding #{id} not found" unless found

          found.status = status
          found.resolved_at = terminal ? Time.now : nil
          found.resolved_by = actor&.to_s
          found.resolution_reason = reason
        end

        Telemetry.emit("factory.finding_resolved",
                       dims: { status: status, actor: actor }, measures: { count: 1 })
        found
      end

      # ─── Experiment ──────────────────────────────────────────────────────────

      def experiment!(finding_or_id, target:, variant:, control: nil, traffic_pct: 10,
                      bucket_by: :account, level: nil, cohort: {})
        finding =
          if finding_or_id.is_a?(Finding)
            finding_or_id
          else
            findings.find { |candidate| candidate.id.to_s == finding_or_id.to_s }
          end
        level ||= finding&.suggested_level || :n1
        level = level.to_sym

        if level == :n5
          raise ConfigurationError,
                "Level N5 changes are emitted as patches for review, not executed. Use Factory.patch!"
        end
        raise ConfigurationError, "Unknown intervention level: #{level}" unless LEVELS.key?(level)
        validate_intervention!(target, level, control, variant)
        ensure_no_overlapping_experiment!(target, cohort)

        now = Time.now
        baseline = baseline_metrics(target: target, cohort: cohort, before: now)

        exp = Experiment.new(
          id: SecureRandom.uuid, name: "#{target}-#{Time.now.to_i}", level: level.to_s,
          target: target.to_s, control: control, variant: variant,
          traffic_pct: traffic_pct, bucket_by: bucket_by.to_s, status: "running",
          finding_id: finding&.id, started_at: now, cohort: stringify_keys(cohort),
          results: baseline, tenant_key: factory_scope.tenant_key || "__global__",
          account_id: factory_scope.account_id
        )

        if persisted?
          Agentkit::ExperimentRecord.transaction do
            lock_experiment_registry!
            ensure_no_overlapping_experiment!(target, cohort)
            row = Agentkit::ExperimentRecord.create!(
              name: exp.name, level: exp.level, target: exp.target,
              control: exp.control.nil? ? {} : exp.control,
              variant: exp.variant.nil? ? {} : exp.variant,
              traffic_pct: exp.traffic_pct, bucket_by: exp.bucket_by,
              status: exp.status, finding_id: finding&.id, started_at: exp.started_at,
              cohort: exp.cohort, results: exp.results,
              tenant_key: exp.tenant_key, account_id: exp.account_id
            )
            exp.id = row.id.to_s
            finding_relation.lock.where(id: finding.id).update_all(
              status: "experimenting", resolved_at: nil, updated_at: now
            ) if finding
            apply_variant(exp)
          end
          exp = experiment_from(experiment_relation.find(exp.id))
        else
          (@experiments ||= []) << exp
          apply_variant(exp)
          finding.status = "experimenting" if finding
        end
        Telemetry.emit("factory.experiment.started",
                       dims: { experiment_id: exp.id, target: exp.target, level: exp.level },
                       measures: { traffic_pct: traffic_pct })
        exp
      rescue StandardError
        safely_rollback_intervention(exp) if defined?(exp) && exp
        raise
      end

      # ─── Evaluate ────────────────────────────────────────────────────────────

      # Promotion needs samples, effect, significance, no golden-set regression
      # and a cost guard. Never "the LLM judged the new version better".
      def evaluate(experiment)
        original = experiment if experiment.is_a?(Experiment)
        experiment = reload_experiment(experiment)
        unless experiment.status == "running"
          sync_experiment!(original, experiment)
          return { verdict: :ignored, reason: :not_running }
        end

        if persisted?
          row = experiment_relation.find(experiment.id)
          verdict = row.with_lock do
            current = experiment_from(row)
            evaluate_unlocked(current, row: row)
          end
          sync_experiment!(original, experiment_from(row.reload))
          return verdict
        end
        evaluate_unlocked(experiment).tap { sync_experiment!(original, experiment) }
      end

      def evaluate_unlocked(experiment, row: nil)
        rules = Agentkit.config.factory.promotion
        entries = experiment_entries(experiment)
        if experiment.level == "n2"
          control_entries = entries.select { |entry| entry.experiment_arm == "control" }
          variant_entries = entries.select { |entry| entry.experiment_arm == "variant" }
          control_n = control_entries.size
          control_successes = accepted_count(control_entries)
        else
          # Parameter/policy/composition adapters normally apply globally: they
          # cannot expose a concurrent control arm without lying about which
          # value was active. Their control is the bounded pre-change window
          # captured transactionally before apply_variant; post-change human
          # decisions form the variant cohort.
          control_entries = []
          variant_entries = entries
          control_n = result_value(experiment.results, :baseline_n).to_i
          baseline_acceptance = result_value(experiment.results, :baseline_acceptance)
          control_successes = baseline_acceptance.nil? ? 0 : (baseline_acceptance.to_f * control_n).round
        end

        if control_n < rules[:min_samples] || variant_entries.size < rules[:min_samples]
          return decision(experiment, :inconclusive, reason: :insufficient_samples,
                                                     control_n: control_n,
                                                     variant_n: variant_entries.size, row: row)
        end

        stats = Telemetry::Significance.proportions(
          control_successes: control_successes, control_n: control_n,
          variant_successes: accepted_count(variant_entries), variant_n: variant_entries.size,
          confidence: rules[:significance]
        )

        return decision(experiment, :inconclusive, **stats.merge(reason: :not_significant), row: row) unless stats[:significant]
        return decision(experiment, :rollback, **stats.merge(reason: :negative_effect), row: row) if stats[:effect] < 0
        if stats[:effect] < rules[:min_effect]
          return decision(experiment, :inconclusive, **stats.merge(reason: :effect_too_small), row: row)
        end

        if (elapsed = Time.now - experiment.started_at) < rules[:min_duration]
          return decision(experiment, :inconclusive, reason: :too_soon,
                                                     elapsed: elapsed.round, row: row)
        end

        golden = golden_set_result(experiment)
        unless golden[:available]
          return decision(experiment, :inconclusive, reason: golden[:reason], row: row)
        end
        if golden[:regressions].any?
          return decision(experiment, :rollback, reason: :golden_set_regression,
                                                   cases: golden[:regressions], row: row)
        end

        cost = experiment_cost_result(experiment, control_entries, variant_entries)
        unless cost[:available]
          return decision(experiment, :inconclusive, reason: :cost_data_unavailable, row: row)
        end
        if cost[:ratio] > rules[:cost_guard].to_f
          return decision(experiment, :rollback, reason: :cost_regression,
                                                   cost: cost, row: row)
        end

        decision(experiment, :adopt, **stats.merge(cost: cost), row: row)
      end

      # Guardrails abort an experiment on their own, without a human.
      def enforce_guardrails!(experiment)
        experiment = reload_experiment(experiment)
        return :not_running unless experiment.status == "running"

        rules = Agentkit.config.factory.guardrails
        entries = experiment_entries(experiment)
        variant = entries.select { |entry| entry.experiment_arm == "variant" }
        return :ok if variant.size < 10

        acceptance = accepted_count(variant).to_f / variant.size
        baseline = result_value(experiment.results, :baseline_acceptance)
        if baseline && acceptance && (baseline - acceptance) > rules[:max_acceptance_drop]
          rollback!(experiment, reason: :guardrail_acceptance)
          return :rolled_back
        end

        control = entries.select { |entry| entry.experiment_arm == "control" }
        cost = experiment_cost_result(experiment, control, variant)
        if cost[:available] && (cost[:ratio] - 1.0) > rules[:max_cost_increase].to_f
          rollback!(experiment, reason: :guardrail_cost)
          return :rolled_back
        end
        :ok
      end

      def adopt!(experiment, results: nil, row: nil)
        original = experiment if experiment.is_a?(Experiment)
        experiment = reload_experiment(experiment) unless row
        apply_adoption(experiment)
        finish_experiment!(experiment, "adopted", results: results, row: row)
        transition_finding!(experiment.finding_id, "resolved",
                            actor: "factory", reason: "experiment_adopted")
        Telemetry.emit("factory.experiment.adopted",
                       dims: { experiment_id: experiment.id, target: experiment.target })
        sync_experiment!(original, experiment)
      end

      def rollback!(experiment, reason: nil, results: nil, row: nil)
        original = experiment if experiment.is_a?(Experiment)
        experiment = reload_experiment(experiment) unless row
        apply_rollback(experiment)
        merged = (results || experiment.results || {}).merge("rollback_reason" => reason&.to_s)
        finish_experiment!(experiment, "rolled_back", results: merged, row: row)
        transition_finding!(experiment.finding_id, "accepted",
                            actor: "factory", reason: "experiment_rolled_back")
        Telemetry.emit("factory.experiment.rolled_back",
                       dims: { experiment_id: experiment.id, target: experiment.target,
                               reason: reason })
        sync_experiment!(original, experiment)
      end

      # ─── Golden set ──────────────────────────────────────────────────────────

      # Rejected and edited decisions become evaluation cases with the human's
      # correction as the expected output. Three months of this is a
      # domain-specific regression set no public benchmark matches — and v0.1
      # was throwing it away.
      def capture_golden!(since: nil)
        rules   = Agentkit.config.factory.golden_set
        entries = HITL.ledger.entries(since: since, mode: "human", scope: factory_scope)
        captured = 0

        entries.each do |entry|
          next unless Array(rules[:capture]).map(&:to_s).include?(entry.decision) ||
                      (entry.decision == "accepted" && Kernel.rand < rules[:sample].to_f)

          next if golden_sets[entry.agent_name].size >= rules[:max_per_agent]
          next if golden_sets[entry.agent_name].any? do |golden_case|
            golden_case.suggestion_id.to_s == entry.suggestion_id.to_s
          end

          golden_case = GoldenCase.new(
            id: SecureRandom.uuid, agent_name: entry.agent_name,
            suggestion_id: entry.suggestion_id,
            input: entry.proposed_payload || {},
            expected: blank_payload?(entry.final_payload) ? (entry.proposed_payload || {}) : entry.final_payload,
            label: entry.decision, rejection_code: entry.rejection_code,
            frozen: !rules[:freeze_after_review], captured_at: Time.now,
            tenant_key: factory_scope.tenant_key || "__global__", account_id: factory_scope.account_id
          )
          if golden_persisted?
            Agentkit::GoldenCaseRecord.create!(
              agent_name: golden_case.agent_name,
              suggestion_id: golden_case.suggestion_id,
              input: golden_case.input, expected: golden_case.expected,
              label: golden_case.label, rejection_code: golden_case.rejection_code,
              reviewed: golden_case.frozen, tenant_key: golden_case.tenant_key,
              account_id: golden_case.account_id
            )
          else
            golden_sets[entry.agent_name] << golden_case
          end
          captured += 1
        end
        Telemetry.emit("factory.golden_captured", measures: { count: captured })
        captured
      end

      def freeze_golden!(agent, case_id)
        if golden_persisted?
          row = golden_relation.find_by(id: case_id, agent_name: agent.to_s)
          return nil unless row

          row.update!(reviewed: true)
          return golden_case_from(row)
        end

        found = golden_sets[agent.to_s].find { |golden_case| golden_case.id.to_s == case_id.to_s }
        found.frozen = true if found
        found
      end

      def register_golden_runner(target = :default, &block)
        raise ArgumentError, "a golden runner block is required" unless block

        golden_runners[target.to_s] = block
      end

      def golden_set_result(experiment)
        gate = Agentkit.config.factory.promotion[:golden_set_gate]
        return { available: true, regressions: [] } if gate.nil? || gate == :off

        runner = golden_runners[experiment.target.to_s] || golden_runners["default"]
        return { available: false, reason: :golden_runner_unavailable } unless runner

        agent = result_value(experiment.cohort, :agent_name)
        cases =
          if agent
            golden_sets[agent.to_s]
          else
            golden_sets.values.flatten
          end
        cases = cases.select(&:frozen)
        return { available: false, reason: :golden_set_empty } if cases.empty?

        regressions = Array(runner.call(experiment, cases)).compact
        { available: true, regressions: regressions }
      rescue StandardError => e
        Agentkit.logger&.error("[AgentKit::Factory] golden runner failed: #{e.class}: #{e.message}")
        { available: false, reason: :golden_runner_failed }
      end

      # ─── Level 5: patches, never writes ──────────────────────────────────────

      # Emits a reviewable patch (branch + diff + the finding that motivated it).
      # It never touches the filesystem — that is exactly what made nobody
      # enable v0.1's factory.
      def patch!(finding, files: {}, rationale: nil)
        patch = {
          id: SecureRandom.uuid, finding_id: finding.id, level: "n5",
          branch: "agentkit/factory/#{finding.detector}-#{Time.now.to_i}",
          rationale: rationale || finding.summary,
          diff: files, created_at: Time.now, status: "for_review"
        }
        patches << patch
        Telemetry.emit("factory.patch_emitted", dims: { detector: finding.detector })
        patch
      end

      def patches = @patches ||= []

      # ─── Report ──────────────────────────────────────────────────────────────

      def report(window: 7 * 86_400, format: :md)
        snap = Snapshot.new(window: window)
        data = {
          period_days: (window / 86_400.0).round(1),
          agents: snap.agents.map do |agent|
            { agent: agent,
              acceptance: snap.acceptance_rate(agent: agent),
              clean_acceptance: snap.clean_acceptance_rate(agent: agent),
              ignore_rate: snap.ignore_rate(agent: agent),
              rejection_profile: snap.rejection_profile(agent: agent),
              cost_per_accepted: snap.cost_per_accepted(agent: agent) }
          end,
          llm: snap.llm_stats.to_h,
          spend_usd: snap.sum("llm.call", :cost_usd).round(4),
          embeddings: snap.sum("embedding.generate", :count).to_i,
          findings: findings.select { |f| f.status == "open" }.map(&:to_h),
          experiments: experiments.map { |e| { target: e.target, status: e.status } }
        }
        format == :md ? to_markdown(data) : data
      end

      def install_default_detectors!
        return if @defaults_installed

        Detectors.register(:acceptance_drop, severity: :high, level: :n2) do |s|
          s.agents.filter_map do |agent|
            now  = s.acceptance_rate(agent: agent)
            prev = s.previous(agent: agent)
            next if now.nil? || prev.nil? || prev.zero?

            drop = prev - now
            next unless drop >= 0.15

            { subject: agent, summary: "Acceptance fell #{(drop * 100).round}pp for #{agent}",
              now: now, previous: prev.round(4) }
          end.first
        end

        Detectors.register(:rejection_cluster, severity: :high, level: :n2) do |s|
          s.agents.filter_map do |agent|
            profile = s.rejection_profile(agent: agent)
            dominant = profile.max_by { |_, share| share }
            next if dominant.nil? || dominant.last < 0.4

            { subject: agent, summary: "#{(dominant.last * 100).round}% of #{agent} rejections are `#{dominant.first}`",
              code: dominant.first, share: dominant.last, profile: profile }
          end.first
        end

        Detectors.register(:ignored_proposals, severity: :medium, level: :n1) do |s|
          s.agents.filter_map do |agent|
            rate = s.ignore_rate(agent: agent)
            next if rate.nil? || rate <= 0.5

            { subject: agent, summary: "#{(rate * 100).round}% of #{agent} proposals are never decided — noise",
              ignore_rate: rate }
          end.first
        end

        # The metric that decides whether RAG is worth its embedding bill.
        Detectors.register(:retrieval_useless, severity: :medium, level: :n1) do |s|
          used  = s.rate("memory.recall.used", :used_in_output)
          spend = s.sum("embedding.generate", :cost_usd)
          next if s.count("memory.recall.used").zero? || spend <= 0
          next if used >= 0.2

          { subject: "memory", summary: "Only #{(used * 100).round}% of recalls influence the answer while embeddings cost $#{spend.round(4)}",
            used_rate: used, embedding_spend: spend.round(4) }
        end

        Detectors.register(:cost_spike, severity: :high, level: :n1) do |s|
          s.agents.filter_map do |agent|
            cost = s.cost_per_accepted(agent: agent)
            next if cost.nil? || cost < 0.5

            { subject: agent, summary: "#{agent} costs $#{cost.round(4)} per accepted proposal", cost_per_accepted: cost }
          end.first
        end

        Detectors.register(:schema_thrash, severity: :medium, level: :n2) do |s|
          events = s.events("llm.call")
          next if events.size < 20

          violations = events.sum { |e| e.measures[:schema_violations].to_i }
          rate = violations.to_f / events.size
          next if rate <= 0.05

          { subject: "llm", summary: "#{(rate * 100).round}% of calls fail their schema on first try", rate: rate }
        end

        Detectors.register(:model_overkill, severity: :low, level: :n1) do |s|
          by_model = s.llm_stats(by: :profile)
          complex  = by_model[:complex]
          next if complex.nil? || complex.n < 20

          total = by_model.values.sum(&:n)
          share = complex.n.to_f / total
          next if share < 0.5

          { subject: "routing", summary: "#{(share * 100).round}% of calls use the :complex profile", share: share }
        end

        Detectors.register(:join_starvation, severity: :medium, level: :n1) do |s|
          waits = s.events("flow.join.waiting")
          total = s.count("flow.join.resolve") + waits.size
          next if total < 10

          rate = waits.size.to_f / total
          next if rate <= 0.1

          { subject: "flow", summary: "#{(rate * 100).round}% of joins time out or wait", rate: rate }
        end

        Detectors.register(:capability_gap, severity: :high, level: :n4) do |_s|
          gaps = Proposals.gaps
          next if gaps.size < 5

          { subject: "capabilities", summary: "#{gaps.size} user intents had no capability behind them",
            samples: gaps.last(5).map { |g| g[:text] } }
        end

        @defaults_installed = true
      end

      private

      def plan_for(finding)
        planner = Plans.fetch(finding.detector)
        unless planner
          Telemetry.emit("factory.plan_unavailable", dims: { detector: finding.detector })
          return nil
        end

        raw = planner.call(finding)
        return nil if raw.nil?

        plan = symbolize_keys(raw)
        %i[target variant level].each do |required|
          raise ConfigurationError, "Factory plan for #{finding.detector} needs #{required}" unless plan.key?(required)
        end
        validate_intervention!(plan[:target], plan[:level].to_sym, plan[:control], plan[:variant])
        plan
      end

      def start_plan!(finding, plan)
        experiment!(
          finding, target: plan.fetch(:target), control: plan[:control],
          variant: plan.fetch(:variant), level: plan.fetch(:level),
          traffic_pct: plan.fetch(:traffic_pct, 10),
          bucket_by: plan.fetch(:bucket_by, :account), cohort: plan.fetch(:cohort, {})
        )
      end

      def ensure_intervention_handler!
        @intervention_handler ||= lambda { |suggestion| start_intervention_suggestion!(suggestion) }
        handlers = HITL.handlers["factory_intervention"]
        HITL.on("factory_intervention", &@intervention_handler) unless handlers.include?(@intervention_handler)
      end

      def accepted_count(entries)
        entries.count { |entry| %w[accepted edited].include?(entry.decision) }
      end

      def apply_variant(experiment)
        if experiment.level == "n2"
          prompt_id = experiment.target.split(":", 2).last
          Prompt.canary(prompt_id, version: experiment.variant, percent: experiment.traffic_pct,
                                   bucket: experiment.bucket_by.to_sym,
                                   experiment_id: experiment.id)
        else
          Interventions.fetch(experiment.target).apply.call(experiment)
        end
      end

      def apply_adoption(experiment)
        if experiment.level == "n2"
          Prompt.promote(experiment.target.split(":", 2).last, version: experiment.variant)
        else
          Interventions.fetch(experiment.target).adopt.call(experiment)
        end
      end

      def apply_rollback(experiment)
        if experiment.level == "n2"
          prompt_id = experiment.target.split(":", 2).last
          if experiment.control.nil? || experiment.control == {}
            Prompt.stop_canary(prompt_id)
          else
            Prompt.rollback(prompt_id, to: experiment.control)
          end
        else
          Interventions.fetch(experiment.target).rollback.call(experiment)
        end
      end

      def safely_rollback_intervention(experiment)
        apply_rollback(experiment)
      rescue StandardError => e
        Agentkit.logger&.error("[AgentKit::Factory] failed to compensate intervention: #{e.message}")
      end

      def decision(experiment, verdict, row: nil, **data)
        merged = stringify_keys(experiment.results || {})
                 .merge(stringify_keys(data))
                 .merge("verdict" => verdict.to_s)
        experiment.results = merged
        experiment.last_evaluated_at = Time.now
        case verdict
        when :adopt
          adopt!(experiment, results: merged, row: row)
        when :rollback
          rollback!(experiment, reason: data[:reason], results: merged, row: row)
        else
          experiment.status = "running"
          persist_experiment_progress!(experiment, row: row)
        end
        { verdict: verdict, **data }
      end

      def finding_for(experiment)
        findings.find { |finding| finding.id.to_s == experiment.finding_id.to_s }
      end

      def finish_experiment!(experiment, status, results:, row: nil)
        now = Time.now
        experiment.status = status
        experiment.finished_at = now
        experiment.results = stringify_keys(results || {})
        if persisted?
          row ||= experiment_relation.find(experiment.id)
          row.update!(status: status, results: experiment.results,
                      finished_at: now, last_evaluated_at: experiment.last_evaluated_at || now)
        end
        experiment
      end

      def persist_experiment_progress!(experiment, row: nil)
        return experiment unless persisted?

        row ||= experiment_relation.find(experiment.id)
        row.update!(status: experiment.status, results: stringify_keys(experiment.results || {}),
                    last_evaluated_at: experiment.last_evaluated_at || Time.now)
        experiment
      end

      def transition_finding!(finding_id, status, actor:, reason:)
        return if finding_id.nil?

        if persisted?
          row = finding_relation.find_by(id: finding_id)
          return unless row

          terminal = status == "resolved"
          row.update!(status: status, resolved_at: terminal ? Time.now : nil,
                      resolved_by: actor, resolution_reason: reason)
        else
          finding = (@findings ||= []).find { |candidate| candidate.id.to_s == finding_id.to_s }
          return unless finding

          finding.status = status
          finding.resolved_at = status == "resolved" ? Time.now : nil
          finding.resolved_by = actor
          finding.resolution_reason = reason
        end
      end

      def reload_experiment(experiment)
        experiment = experiments.find { |candidate| candidate.id.to_s == experiment.to_s } unless
          experiment.is_a?(Experiment)
        raise ConfigurationError, "Experiment not found" unless experiment

        return experiment unless persisted?

        row = experiment_relation.find_by(id: experiment.id)
        raise ConfigurationError, "Experiment #{experiment.id} not found" unless row

        experiment_from(row)
      end

      def sync_experiment!(target, source)
        return source if target.nil? || target.equal?(source)

        Experiment.members.each { |member| target.public_send("#{member}=", source.public_send(member)) }
        target
      end

      def experiment_entries(experiment)
        filters = { since: experiment.started_at, mode: "human" }
        # Prompt canaries carry both arms concurrently, so experiment_id is the
        # isolation boundary. Global reversible adapters use a temporal control
        # captured before they are applied and therefore have no runtime arm id.
        filters[:experiment_id] = experiment.id if experiment.level == "n2"
        entries = HITL.ledger.entries(**filters, scope: factory_scope)
        entries.select { |entry| cohort_match?(entry, experiment) }
      end

      def cohort_match?(entry, experiment)
        cohort = stringify_keys(experiment.cohort || {})
        required = cohort.all? do |key, value|
          case key
          when "agent_name"      then entry.agent_name.to_s == value.to_s
          when "suggestion_type" then entry.suggestion_type.to_s == value.to_s
          when "tenant_key"      then entry.tenant_key.to_s == value.to_s
          when "prompt_id"       then entry.prompt_id.to_s == value.to_s
          else true
          end
        end
        return false unless required

        experiment.level != "n2" ||
          entry.prompt_id.to_s == experiment.target.split(":", 2).last.to_s
      end

      def experiment_cost_result(experiment, control_entries, variant_entries)
        return temporal_experiment_cost_result(experiment, variant_entries) unless experiment.level == "n2"

        events = Telemetry.events(name: "llm.call", since: experiment.started_at).select do |event|
          event.dims[:experiment_id].to_s == experiment.id.to_s
        end
        by_arm = events.group_by { |event| event.dims[:experiment_arm].to_s }
        return { available: false } if by_arm["control"].to_a.empty? || by_arm["variant"].to_a.empty?
        return { available: false } if control_entries.empty? || variant_entries.empty?

        control = by_arm["control"].sum { |event| event.measures[:cost_usd].to_f } / control_entries.size
        variant = by_arm["variant"].sum { |event| event.measures[:cost_usd].to_f } / variant_entries.size
        ratio = control.zero? ? (variant.zero? ? 1.0 : Float::INFINITY) : variant / control
        { available: true, control_per_decision: control.round(6),
          variant_per_decision: variant.round(6), ratio: ratio.round(4) }
      end

      def temporal_experiment_cost_result(experiment, variant_entries)
        control = result_value(experiment.results, :baseline_cost_per_decision)
        events = Telemetry.events(name: "llm.call", since: experiment.started_at)
                          .select { |event| telemetry_cohort_match?(event, experiment.cohort) }
        return { available: false } if control.nil? || variant_entries.empty? || events.empty?

        variant = events.sum { |event| event.measures[:cost_usd].to_f } / variant_entries.size
        control = control.to_f
        ratio = control.zero? ? (variant.zero? ? 1.0 : Float::INFINITY) : variant / control
        { available: true, control_per_decision: control.round(6),
          variant_per_decision: variant.round(6), ratio: ratio.round(4) }
      end

      def baseline_metrics(target:, cohort:, before:)
        window = Agentkit.config.factory.baseline_window.to_f
        entries = HITL.ledger.entries(since: before - window, mode: "human").select do |entry|
          entry.created_at < before && baseline_entry_match?(entry, target, cohort)
        end
        events = Telemetry.events(name: "llm.call", since: before - window).select do |event|
          event.occurred_at < before && telemetry_cohort_match?(event, cohort)
        end
        acceptance =
          if entries.empty?
            nil
          else
            accepted_count(entries).to_f / entries.size
          end
        cost =
          if entries.empty? || events.empty?
            nil
          else
            events.sum { |event| event.measures[:cost_usd].to_f } / entries.size
          end
        { "baseline_acceptance" => acceptance,
          "baseline_n" => entries.size,
          "baseline_cost_per_decision" => cost,
          "baseline_captured_at" => before.utc.iso8601 }
      end

      def telemetry_cohort_match?(event, cohort)
        stringify_keys(cohort || {}).all? do |key, value|
          case key
          when "agent_name" then event.dims[:agent].to_s == value.to_s
          when "prompt_id"  then event.dims[:prompt_id].to_s == value.to_s
          when "tenant_key" then event.dims[:tenant].to_s == value.to_s
          else true
          end
        end
      end

      def baseline_entry_match?(entry, target, cohort)
        pseudo = Experiment.new(level: target.to_s.start_with?("prompt:") ? "n2" : "n1",
                                target: target.to_s, cohort: cohort)
        cohort_match?(entry, pseudo)
      end

      def validate_intervention!(target, level, control, variant)
        raise ConfigurationError, "An experiment needs a variant" if variant.nil?

        if level == :n2
          raise ConfigurationError, "N2 targets must use prompt:<id>" unless target.to_s.start_with?("prompt:")

          prompt_id = target.to_s.split(":", 2).last
          raise ConfigurationError, "Unknown prompt #{prompt_id}" unless Prompt.defined?(prompt_id)
          unless Prompt.versions(prompt_id).include?(variant)
            raise ConfigurationError, "Prompt #{prompt_id} variant #{variant.inspect} is not defined"
          end
          return
        end

        adapter = Interventions.fetch(target)
        raise ConfigurationError, "Intervention #{target} is #{adapter.level}, not #{level}" unless
          adapter.level == level.to_s
        raise ConfigurationError, "A reversible #{level} experiment needs a control value" if control.nil?
      end

      def ensure_no_overlapping_experiment!(target, cohort)
        running =
          if persisted?
            experiment_relation.where(status: "running").map { |row| experiment_from(row) }
          else
            (@experiments || []).select { |experiment| experiment.status == "running" }
          end
        conflict = running.find { |experiment| cohorts_overlap?(experiment.cohort, cohort) }
        return unless conflict

        raise ConfigurationError,
              "Experiment #{conflict.id} on #{conflict.target} already overlaps the cohort for #{target}"
      end

      def cohorts_overlap?(left, right)
        left = stringify_keys(left || {})
        right = stringify_keys(right || {})
        return true if left.empty? || right.empty?

        shared = left.keys & right.keys
        return true if shared.empty?

        shared.none? { |key| left[key].to_s != right[key].to_s }
      end

      def lock_experiment_registry!
        connection = Agentkit::ExperimentRecord.connection
        return unless connection.adapter_name.to_s.downcase.include?("postgres")

        key = "agentkit_factory_experiments:#{factory_scope.tenant_key || '__global__'}"
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(key)}))")
      end

      def finding_fingerprint(detector, subject)
        Digest::SHA256.hexdigest([detector, subject].map { |value| value.to_s.strip.downcase }.join(":"))
      end

      def auto_resolve_quiet_findings!(fired_fingerprints, failed_detectors: [])
        threshold = Agentkit.config.factory.resolve_after_clean_cycles.to_i
        return if threshold <= 0

        if persisted?
          finding_relation.where(status: "open").find_each do |row|
            next if fired_fingerprints.include?(row.fingerprint)
            next if failed_detectors.include?(row.detector.to_s)

            cycles = row.clean_cycles.to_i + 1
            attrs = { clean_cycles: cycles }
            if cycles >= threshold
              attrs.merge!(status: "resolved", resolved_at: Time.now,
                           resolved_by: "factory",
                           resolution_reason: "detector_clean_for_#{cycles}_cycles")
            end
            row.update!(attrs)
          end
        else
          (@findings ||= []).select { |finding| finding.status == "open" }.each do |finding|
            next if fired_fingerprints.include?(finding.fingerprint)
            next if failed_detectors.include?(finding.detector.to_s)

            finding.clean_cycles = finding.clean_cycles.to_i + 1
            next unless finding.clean_cycles >= threshold

            finding.status = "resolved"
            finding.resolved_at = Time.now
            finding.resolved_by = "factory"
            finding.resolution_reason = "detector_clean_for_#{finding.clean_cycles}_cycles"
          end
        end
      end

      def golden_persisted?
        persisted? && defined?(Agentkit::GoldenCaseRecord) && Agentkit::GoldenCaseRecord.table_exists?
      end

      def factory_scope = Scope.resolve

      def finding_relation
        apply_factory_scope(Agentkit::FindingRecord.all)
      end

      def experiment_relation
        apply_factory_scope(Agentkit::ExperimentRecord.all)
      end

      def golden_relation
        apply_factory_scope(Agentkit::GoldenCaseRecord.all)
      end

      def apply_factory_scope(relation)
        scope = factory_scope
        relation = relation.where(tenant_key: scope.tenant_key) if scope.tenant_key
        relation = relation.where(account_id: scope.account_id) if scope.account_id && relation.column_names.include?("account_id")
        relation
      end

      def golden_runners = @golden_runners ||= {}

      def attribute(row, name)
        row.has_attribute?(name) ? row.public_send(name) : nil
      end

      def result_value(hash, key)
        (hash || {})[key] || (hash || {})[key.to_s]
      end

      def stringify_keys(hash)
        (hash || {}).each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def symbolize_keys(hash)
        (hash || {}).each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
      end

      def deep_symbolize_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), out|
            out[key.respond_to?(:to_sym) ? key.to_sym : key] = deep_symbolize_keys(nested)
          end
        when Array
          value.map { |nested| deep_symbolize_keys(nested) }
        else
          value
        end
      end

      def blank_payload?(payload)
        payload.nil? || (payload.respond_to?(:empty?) && payload.empty?)
      end

      def to_markdown(data)
        lines = ["# AgentKit factory report", "", "Window: last #{data[:period_days]} days", ""]
        lines << "## Economics"
        lines << "- LLM spend: $#{data[:spend_usd]}"
        lines << "- Embeddings generated: #{data[:embeddings]}"
        lines << ""
        lines << "## Agents"
        data[:agents].each do |a|
          lines << "### #{a[:agent]}"
          lines << "- acceptance: #{pct(a[:acceptance])} (clean: #{pct(a[:clean_acceptance])})"
          lines << "- ignored: #{pct(a[:ignore_rate])}"
          lines << "- cost per accepted: #{a[:cost_per_accepted] ? "$#{a[:cost_per_accepted]}" : 'n/a'}"
          lines << "- rejections: #{a[:rejection_profile].map { |k, v| "#{k} #{pct(v)}" }.join(', ')}" if a[:rejection_profile].any?
          lines << ""
        end
        lines << "## Open findings"
        data[:findings].each { |f| lines << "- [#{f[:severity]}] **#{f[:detector]}** — #{f[:summary]} (level #{f[:level]})" }
        lines << "_none_" if data[:findings].empty?
        lines.join("\n")
      end

      def pct(value) = value.nil? ? "n/a" : "#{(value * 100).round}%"
    end
  end
end
