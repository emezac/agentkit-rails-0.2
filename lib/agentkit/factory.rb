# frozen_string_literal: true

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
                         :suggested_level, :created_at, :status, keyword_init: true) do
      def to_h
        { id: id, detector: detector, severity: severity, subject: subject,
          summary: summary, evidence: evidence, level: suggested_level, status: status }
      end
    end

    Experiment = Struct.new(:id, :name, :level, :target, :control, :variant, :traffic_pct,
                            :bucket_by, :status, :finding_id, :started_at, :results,
                            keyword_init: true)

    # ─── Detectors ─────────────────────────────────────────────────────────────

    module Detectors
      class << self
        def registry = @registry ||= {}

        def register(name, severity: :medium, level: :n1, &block)
          registry[name.to_sym] = { block: block, severity: severity, level: level }
        end

        def reset! = @registry = {}

        def run_all(window:)
          registry.filter_map do |name, spec|
            evidence = spec[:block].call(Snapshot.new(window: window))
            next if evidence.nil? || evidence == false

            Finding.new(
              id: SecureRandom.uuid, detector: name.to_s, severity: spec[:severity],
              subject: evidence[:subject], summary: evidence[:summary],
              evidence: evidence.except(:subject, :summary),
              suggested_level: spec[:level], created_at: Time.now, status: "open"
            )
          end
        end
      end
    end

    # Read-only view over telemetry + ledger for the detectors, so a detector is
    # a pure function of measurements.
    class Snapshot
      attr_reader :window, :since

      def initialize(window:)
        @window = window
        @since  = Time.now - window
      end

      def ledger = HITL.ledger

      def agents
        ledger.entries(since: since).map(&:agent_name).compact.uniq
      end

      def acceptance_rate(agent: nil)       = ledger.acceptance_rate(agent: agent, since: since)
      def clean_acceptance_rate(agent: nil) = ledger.clean_acceptance_rate(agent: agent, since: since)
      def ignore_rate(agent: nil)           = ledger.ignore_rate(agent: agent, since: since)
      def rejection_profile(agent: nil)     = ledger.rejection_profile(agent: agent, since: since)
      def cost_per_accepted(agent: nil)     = ledger.cost_per_accepted(agent: agent, since: since)

      def previous(agent: nil, metric: :acceptance_rate)
        prev_since = since - window
        entries = ledger.entries(agent: agent).select { |e| e.created_at.between?(prev_since, since) }
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

      def events(name) = Telemetry.events(name: name, since: since)

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

    class << self
      def findings    = @findings ||= []
      def experiments = @experiments ||= []
      def golden_sets = @golden_sets ||= Hash.new { |h, k| h[k] = [] }

      def reset!
        @findings    = []
        @experiments = []
        @golden_sets = nil
        @patches     = []
        Detectors.reset!
        @defaults_installed = false
        install_default_detectors!
        self
      end

      # ─── Observe → Diagnose ──────────────────────────────────────────────────

      def diagnose!(window: 7 * 86_400)
        install_default_detectors! if Detectors.registry.empty?

        new_findings = Detectors.run_all(window: window)
        new_findings.each do |f|
          next if findings.any? { |existing| existing.detector == f.detector && existing.subject == f.subject && existing.status == "open" }

          findings << f
          Telemetry.emit("factory.finding",
                         dims: { detector: f.detector, severity: f.severity, level: f.suggested_level },
                         measures: { count: 1 })
        end
        new_findings
      end

      # ─── Experiment ──────────────────────────────────────────────────────────

      def experiment!(finding_or_id, target:, variant:, control: nil, traffic_pct: 10,
                      bucket_by: :account, level: nil)
        finding = finding_or_id.is_a?(Finding) ? finding_or_id : findings.find { |f| f.id == finding_or_id }
        level ||= finding&.suggested_level || :n1

        if level.to_sym == :n5
          raise ConfigurationError,
                "Level N5 changes are emitted as patches for review, not executed. Use Factory.patch!"
        end

        exp = Experiment.new(
          id: SecureRandom.uuid, name: "#{target}-#{Time.now.to_i}", level: level.to_s,
          target: target.to_s, control: control, variant: variant,
          traffic_pct: traffic_pct, bucket_by: bucket_by.to_s, status: "running",
          finding_id: finding&.id, started_at: Time.now, results: {}
        )
        experiments << exp
        apply_variant(exp)
        finding&.status = "experimenting"
        Telemetry.emit("factory.experiment.started",
                       dims: { target: exp.target, level: exp.level }, measures: { traffic_pct: traffic_pct })
        exp
      end

      # ─── Evaluate ────────────────────────────────────────────────────────────

      # Promotion needs samples, effect, significance, no golden-set regression
      # and a cost guard. Never "the LLM judged the new version better".
      def evaluate(experiment)
        rules = Agentkit.config.factory.promotion
        ledger = HITL.ledger

        control_entries = ledger.entries(since: experiment.started_at).select { |e| e.prompt_version == control_version(experiment) }
        variant_entries = ledger.entries(since: experiment.started_at).select { |e| e.prompt_version == variant_version(experiment) }

        if control_entries.size < rules[:min_samples] || variant_entries.size < rules[:min_samples]
          return decision(experiment, :inconclusive, reason: :insufficient_samples,
                                                     control_n: control_entries.size, variant_n: variant_entries.size)
        end

        stats = Telemetry::Significance.proportions(
          control_successes: accepted_count(control_entries), control_n: control_entries.size,
          variant_successes: accepted_count(variant_entries), variant_n: variant_entries.size,
          confidence: rules[:significance]
        )

        return decision(experiment, :inconclusive, reason: :not_significant, **stats) unless stats[:significant]
        return decision(experiment, :rollback, reason: :negative_effect, **stats) if stats[:effect] < 0
        return decision(experiment, :inconclusive, reason: :effect_too_small, **stats) if stats[:effect] < rules[:min_effect]

        regression = golden_set_regression(experiment)
        return decision(experiment, :rollback, reason: :golden_set_regression, cases: regression) if regression.any?

        if (elapsed = Time.now - experiment.started_at) < rules[:min_duration]
          return decision(experiment, :inconclusive, reason: :too_soon, elapsed: elapsed.round)
        end

        decision(experiment, :adopt, **stats)
      end

      # Guardrails abort an experiment on their own, without a human.
      def enforce_guardrails!(experiment)
        rules = Agentkit.config.factory.guardrails
        ledger = HITL.ledger
        variant = ledger.entries(since: experiment.started_at).select { |e| e.prompt_version == variant_version(experiment) }
        return :ok if variant.size < 10

        acceptance = ledger.acceptance_rate(since: experiment.started_at)
        baseline   = experiment.results[:baseline_acceptance] || acceptance
        if baseline && acceptance && (baseline - acceptance) > rules[:max_acceptance_drop]
          rollback!(experiment, reason: :guardrail_acceptance)
          return :rolled_back
        end
        :ok
      end

      def adopt!(experiment)
        Prompt.promote(experiment.target.split(":").last, version: experiment.variant) if experiment.level == "n2"
        experiment.status = "adopted"
        finding_for(experiment)&.status = "resolved"
        Telemetry.emit("factory.experiment.adopted", dims: { target: experiment.target })
        experiment
      end

      def rollback!(experiment, reason: nil)
        Prompt.rollback(experiment.target.split(":").last, to: experiment.control) if experiment.level == "n2" && experiment.control
        experiment.status = "rolled_back"
        experiment.results[:rollback_reason] = reason
        Telemetry.emit("factory.experiment.rolled_back", dims: { target: experiment.target, reason: reason })
        experiment
      end

      # ─── Golden set ──────────────────────────────────────────────────────────

      # Rejected and edited decisions become evaluation cases with the human's
      # correction as the expected output. Three months of this is a
      # domain-specific regression set no public benchmark matches — and v0.1
      # was throwing it away.
      def capture_golden!(since: nil)
        rules   = Agentkit.config.factory.golden_set
        entries = HITL.ledger.entries(since: since)
        captured = 0

        entries.each do |entry|
          next unless Array(rules[:capture]).map(&:to_s).include?(entry.decision) ||
                      (entry.decision == "accepted" && Kernel.rand < rules[:sample].to_f)

          set = golden_sets[entry.agent_name]
          next if set.size >= rules[:max_per_agent]
          next if set.any? { |c| c[:suggestion_id] == entry.suggestion_id }

          set << {
            id: SecureRandom.uuid, suggestion_id: entry.suggestion_id,
            input: entry.proposed_payload, expected: entry.final_payload || entry.proposed_payload,
            label: entry.decision, rejection_code: entry.rejection_code,
            frozen: false, captured_at: Time.now
          }
          captured += 1
        end
        Telemetry.emit("factory.golden_captured", measures: { count: captured })
        captured
      end

      def freeze_golden!(agent, case_id)
        found = golden_sets[agent].find { |c| c[:id] == case_id }
        found&.[]=(:frozen, true)
        found
      end

      def golden_set_regression(_experiment)
        [] # replaced by a real re-run when the domain provides a runner
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

      def accepted_count(entries)
        entries.select { |e| e.mode == "human" }.count { |e| %w[accepted edited].include?(e.decision) }
      end

      def control_version(experiment) = experiment.control
      def variant_version(experiment) = experiment.variant

      def apply_variant(experiment)
        return unless experiment.level == "n2"

        prompt_id = experiment.target.split(":").last
        Prompt.canary(prompt_id, version: experiment.variant, percent: experiment.traffic_pct,
                                 bucket: ->(ctx) { ctx&.tenant_key })
      end

      def decision(experiment, verdict, **data)
        experiment.results = experiment.results.merge(data).merge(verdict: verdict)
        case verdict
        when :adopt    then adopt!(experiment)
        when :rollback then rollback!(experiment, reason: data[:reason])
        else experiment.status = "running"
        end
        { verdict: verdict, **data }
      end

      def finding_for(experiment)
        findings.find { |f| f.id == experiment.finding_id }
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
