# frozen_string_literal: true

module Agentkit
  module Harness
    # Stable task identity for matched probes. Inputs and deliverables stay in
    # the host; the experiment stores references and digests only.
    class ExperimentTask
      attr_reader :id, :input_reference, :input_digest, :model, :environment,
                  :output_contract, :metadata

      def initialize(id:, input_reference:, input_digest:, model:, output_contract:,
                     environment: {}, metadata: {})
        @id = required_text(id, "experiment task id").freeze
        @input_reference = required_text(input_reference, "experiment input reference").freeze
        @input_digest = Harness.valid_digest!(input_digest).freeze
        @model = normalize_model(model)
        @environment = normalize_environment(environment)
        @output_contract = frozen_hash(output_contract, "experiment output_contract")
        @metadata = frozen_hash(metadata, "experiment metadata")
        freeze
      end

      def model_digest = Harness.digest(model)
      def environment_digest = Harness.digest(environment)
      def digest = Harness.digest(to_h)

      def safe_for_probe?
        environment["sandboxed"] == true && environment["network"] == false &&
          environment["side_effects"] == "isolated"
      end

      def to_h
        {
          "id" => id, "input_reference" => input_reference, "input_digest" => input_digest,
          "model" => model, "model_digest" => model_digest,
          "environment" => environment, "environment_digest" => environment_digest,
          "output_contract" => output_contract, "metadata" => metadata
        }
      end

      def self.from_h(value)
        data = Harness.stringify_keys(value)
        new(
          id: data.fetch("id"), input_reference: data.fetch("input_reference"),
          input_digest: data.fetch("input_digest"), model: data.fetch("model"),
          environment: data["environment"] || {},
          output_contract: data.fetch("output_contract"), metadata: data["metadata"] || {}
        )
      end

      private

      def normalize_model(value)
        data = value.respond_to?(:to_h) ? value.to_h : { name: value }
        normalized = frozen_hash(data, "experiment model")
        raise HarnessExperimentError, "experiment model name is required" if normalized["name"].to_s.strip.empty?

        normalized
      end

      def normalize_environment(value)
        data = { sandboxed: true, network: false, side_effects: "isolated" }
               .merge(value.respond_to?(:to_h) ? value.to_h : {})
        frozen_hash(data, "experiment environment")
      end

      def frozen_hash(value, label)
        raise HarnessExperimentError, "#{label} must be a hash" unless value.respond_to?(:to_h)

        data = DeclarativeData.normalize(value.to_h, label: label, error_class: HarnessExperimentError)
        Harness.deep_freeze(data)
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise HarnessExperimentError, "#{label} is required" if text.empty?

        text
      end
    end

    class ProbeResult
      STATUSES = %w[ok error].freeze
      ROLES = %w[baseline candidate].freeze

      attr_reader :id, :role, :revision_id, :repetition, :manifest_digest,
                  :task_digest, :model_digest, :environment_digest, :status,
                  :output_reference, :output_digest, :observations, :metrics,
                  :evidence_refs, :error, :started_at, :completed_at

      def initialize(id:, role:, repetition:, manifest_digest:, task_digest:,
                     model_digest:, environment_digest:, status:, revision_id: nil,
                     output_reference: nil, output_digest: nil, observations: [],
                     metrics: {}, evidence_refs: [], error: nil,
                     started_at: Time.now.utc, completed_at: Time.now.utc)
        @id = required_text(id, "probe id").freeze
        @role = role.to_s.freeze
        @revision_id = revision_id&.to_s&.freeze
        @repetition = Integer(repetition)
        @manifest_digest = Harness.valid_digest!(manifest_digest).freeze
        @task_digest = Harness.valid_digest!(task_digest).freeze
        @model_digest = Harness.valid_digest!(model_digest).freeze
        @environment_digest = Harness.valid_digest!(environment_digest).freeze
        @status = status.to_s.freeze
        @output_reference = output_reference&.to_s&.freeze
        @output_digest = output_digest && Harness.valid_digest!(output_digest).freeze
        @observations = frozen_array(observations)
        @metrics = normalize_metrics(metrics)
        @evidence_refs = (["probe:#{id}"] + Array(evidence_refs).map(&:to_s)).reject(&:empty?).uniq.freeze
        @error = error && Harness.deep_freeze(
          DeclarativeData.normalize(error, label: "probe error", error_class: HarnessExperimentError)
        )
        @started_at = Harness.time(started_at)
        @completed_at = Harness.time(completed_at)
        validate!
        freeze
      end

      def successful? = status == "ok"
      def evidence_ref = "probe:#{id}"

      def to_h
        {
          "id" => id, "role" => role, "revision_id" => revision_id,
          "repetition" => repetition, "manifest_digest" => manifest_digest,
          "task_digest" => task_digest, "model_digest" => model_digest,
          "environment_digest" => environment_digest, "status" => status,
          "output_reference" => output_reference, "output_digest" => output_digest,
          "observations" => observations, "metrics" => metrics,
          "evidence_refs" => evidence_refs, "error" => error,
          "started_at" => started_at.iso8601(6), "completed_at" => completed_at.iso8601(6)
        }.compact
      end

      private

      def validate!
        raise HarnessExperimentError, "unknown probe role #{role.inspect}" unless ROLES.include?(role)
        raise HarnessExperimentError, "unknown probe status #{status.inspect}" unless STATUSES.include?(status)
        raise HarnessExperimentError, "probe repetition must be positive" unless repetition.positive?
        if role == "candidate" && revision_id.to_s.empty?
          raise HarnessExperimentError, "candidate probe requires a revision id"
        end
        if successful? && (output_reference.to_s.empty? || output_digest.nil?)
          raise HarnessExperimentError, "successful probe requires output reference and digest"
        end
        if !successful? && error.nil?
          raise HarnessExperimentError, "failed probe requires a redacted error"
        end
      end

      def normalize_metrics(values)
        raise HarnessExperimentError, "probe metrics must be a hash" unless values.respond_to?(:to_h)

        normalized = values.to_h.each_with_object({}) do |(key, value), result|
          number = Float(value)
          raise HarnessExperimentError, "probe metric #{key} must be finite" unless number.finite?
          result[key.to_s] = number
        rescue ArgumentError, TypeError
          raise HarnessExperimentError, "probe metric #{key} must be numeric"
        end
        Harness.deep_freeze(normalized)
      end

      def frozen_array(value)
        data = DeclarativeData.normalize(
          Array(value), label: "probe observations", error_class: HarnessExperimentError
        )
        Harness.deep_freeze(data)
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise HarnessExperimentError, "#{label} is required" if text.empty?

        text
      end
    end

    class ChangeAttribution
      VERDICTS = %w[helped hurt no_observed_effect confounded].freeze

      attr_reader :change_id, :verdict, :observation, :evidence_refs, :confidence

      def initialize(change_id:, verdict:, observation:, evidence_refs:, confidence: nil)
        @change_id = required_text(change_id, "attribution change_id").freeze
        @verdict = verdict.to_s.freeze
        @observation = required_text(observation, "attribution observation").freeze
        @evidence_refs = Array(evidence_refs).map { |value| required_text(value, "evidence reference").freeze }.uniq.freeze
        @confidence = confidence.nil? ? nil : Float(confidence)
        validate!
        freeze
      rescue ArgumentError, TypeError
        raise HarnessExperimentError, "attribution confidence must be between 0 and 1"
      end

      def to_h
        {
          "change_id" => change_id, "verdict" => verdict, "observation" => observation,
          "evidence_refs" => evidence_refs, "confidence" => confidence
        }.compact
      end

      def self.from_h(value)
        data = Harness.stringify_keys(value)
        new(
          change_id: data.fetch("change_id"), verdict: data.fetch("verdict"),
          observation: data.fetch("observation"), evidence_refs: data.fetch("evidence_refs"),
          confidence: data["confidence"]
        )
      end

      private

      def validate!
        raise HarnessExperimentError, "unknown attribution verdict #{verdict.inspect}" unless VERDICTS.include?(verdict)
        raise HarnessExperimentError, "attribution requires evidence" if evidence_refs.empty?
        return if confidence.nil? || confidence.between?(0.0, 1.0)

        raise HarnessExperimentError, "attribution confidence must be between 0 and 1"
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise HarnessExperimentError, "#{label} is required" if text.empty?

        text
      end
    end

    class BehavioralContrast
      attr_reader :id, :revision_id, :baseline_probe_ids, :candidate_probe_ids,
                  :summary, :attributions

      def initialize(id:, revision:, baseline_probes:, candidate_probes:, summary:,
                     attributions:)
        @id = required_text(id, "contrast id").freeze
        @revision_id = revision.id.freeze
        @baseline_probe_ids = Array(baseline_probes).map(&:id).freeze
        @candidate_probe_ids = Array(candidate_probes).map(&:id).freeze
        @summary = required_text(summary, "contrast summary").freeze
        @attributions = Array(attributions).map do |attribution|
          attribution.is_a?(ChangeAttribution) ? attribution : ChangeAttribution.from_h(attribution)
        end.freeze
        validate!(revision, baseline_probes, candidate_probes)
        freeze
      end

      def evidence_ref = "contrast:#{id}"
      def reusable_lesson? = attributions.none? { |item| item.verdict == "confounded" }

      def to_h
        {
          "id" => id, "revision_id" => revision_id,
          "baseline_probe_ids" => baseline_probe_ids,
          "candidate_probe_ids" => candidate_probe_ids,
          "summary" => summary, "attributions" => attributions.map(&:to_h),
          "reusable_lesson" => reusable_lesson?
        }
      end

      private

      def validate!(revision, baseline_probes, candidate_probes)
        expected = revision.changes.map(&:id).sort
        actual = attributions.map(&:change_id).sort
        unless actual == expected
          raise HarnessExperimentError,
                "contrast must attribute every change exactly once (expected #{expected.inspect}, got #{actual.inspect})"
        end

        allowed_refs = (Array(baseline_probes) + Array(candidate_probes)).flat_map(&:evidence_refs).uniq
        unknown = attributions.flat_map(&:evidence_refs).uniq - allowed_refs
        return if unknown.empty?

        raise HarnessExperimentError, "contrast references unknown probe evidence: #{unknown.join(', ')}"
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise HarnessExperimentError, "#{label} is required" if text.empty?

        text
      end
    end

    CompositionReason = Struct.new(:summary, :evidence_refs, keyword_init: true) do
      def to_h = { "summary" => summary.to_s, "evidence_refs" => Array(evidence_refs).map(&:to_s) }
    end

    class Composition
      ACTIONS = %w[keep_base adopt compose].freeze
      KEEP_BASE = "keep_base"

      attr_reader :action, :revision, :reasons

      def initialize(action:, reasons:, available_evidence:, revision: nil)
        normalized = action.to_s.downcase
        normalized = KEEP_BASE if normalized == "keep_base"
        @action = normalized.freeze
        @revision = revision
        @reasons = Array(reasons).map do |reason|
          data = Harness.stringify_keys(reason.respond_to?(:to_h) ? reason.to_h : reason)
          summary = data.fetch("summary").to_s.strip
          refs = Array(data.fetch("evidence_refs")).map(&:to_s).reject(&:empty?).uniq
          raise HarnessExperimentError, "composition reason summary is required" if summary.empty?
          raise HarnessExperimentError, "composition reason requires evidence" if refs.empty?

          CompositionReason.new(summary: summary.freeze, evidence_refs: refs.freeze).freeze
        end.freeze
        validate!(Array(available_evidence).map(&:to_s))
        freeze
      end

      def keep_base? = action == KEEP_BASE

      def to_h
        {
          "action" => action, "revision_id" => revision&.id,
          "revision_digest" => revision&.digest, "reasons" => reasons.map(&:to_h)
        }.compact
      end

      private

      def validate!(available_evidence)
        raise HarnessExperimentError, "unknown composition action #{action.inspect}" unless ACTIONS.include?(action)
        raise HarnessExperimentError, "composition requires at least one evidenced reason" if reasons.empty?
        if keep_base? && revision
          raise HarnessExperimentError, "KEEP_BASE cannot carry a revision"
        elsif !keep_base? && revision.nil?
          raise HarnessExperimentError, "#{action} composition requires a revision"
        end

        unknown = reasons.flat_map(&:evidence_refs).uniq - available_evidence
        return if unknown.empty?

        raise HarnessExperimentError, "composition references unknown evidence: #{unknown.join(', ')}"
      end
    end

    class ExperimentResult
      attr_reader :scope
      attr_reader :id, :base_manifest, :task, :revisions, :validations,
                  :probes, :contrasts, :composition, :selected_manifest,
                  :started_at, :completed_at

      def initialize(id:, base_manifest:, task:, revisions:, validations:, probes:,
                     contrasts:, composition:, selected_manifest:, started_at:, completed_at:, scope: nil)
        @scope = scope && Harness.deep_freeze(DeclarativeData.normalize(scope, label: "experiment scope"))
        @id = id.to_s.freeze
        @base_manifest = base_manifest
        @task = task
        @revisions = revisions.freeze
        @validations = validations.freeze
        @probes = probes.freeze
        @contrasts = contrasts.freeze
        @composition = composition
        @selected_manifest = selected_manifest
        @started_at = Harness.time(started_at)
        @completed_at = Harness.time(completed_at)
        freeze
      end

      def kept_base? = composition.keep_base?
      def selected_revision = composition.revision
      def digest = Harness.digest(to_h)

      def to_h
        {
          "id" => id, "scope" => scope, "base_manifest_digest" => base_manifest.digest,
          "task_digest" => task.digest, "revision_digests" => revisions.map(&:digest),
          "validations" => validations.map(&:to_h), "probes" => probes.map(&:to_h),
          "contrasts" => contrasts.map(&:to_h), "composition" => composition.to_h,
          "selected_manifest_digest" => selected_manifest.digest,
          "started_at" => started_at.iso8601(6), "completed_at" => completed_at.iso8601(6)
        }
      end
    end

    # Local, deterministic orchestration of Propose -> Probe -> Compose. Model
    # adapters are injected; the control plane itself never invokes an LLM,
    # shell, network, or candidate-provided code.
    class Experiment
      attr_reader :id, :base_manifest, :task, :proposer, :executor, :contrastor,
                  :composer, :validator, :repetitions, :context, :goal

      def initialize(base:, task:, proposer:, executor:, contrastor:, composer:,
                     validator: CandidateValidator.new, repetitions: 1, id: nil,
                     context: nil, goal: nil)
        @id = (id || SecureRandom.uuid).to_s.freeze
        @base_manifest = base.is_a?(Manifest) ? base : Manifest.from_h(base)
        @task = task.is_a?(ExperimentTask) ? task : ExperimentTask.from_h(task)
        @proposer = callable!(proposer, "proposer")
        @executor = callable!(executor, "executor")
        @contrastor = callable!(contrastor, "contrastor")
        @composer = callable!(composer, "composer")
        @validator = validator
        @repetitions = integer_repetitions(repetitions)
        @context = context || Context.resolve
        @goal = goal.nil? || goal.is_a?(Goal) ? goal : Goal.from_h(goal)
        validate!
      end

      def run
        started_at = Time.now.utc
        emit("harness.experiment.started", measures: { repetitions: repetitions })
        revisions = propose
        reports = revisions.map do |revision|
          validator.validate(base: base_manifest, revision: revision, goal: goal)
        end
        valid_reports = reports.select(&:valid?)
        probes = valid_reports.empty? ? [] : execute_probes(valid_reports)
        contrasts = build_contrasts(valid_reports, probes)
        composition = compose(revisions, reports, probes, contrasts)
        selected_manifest = composition.keep_base? ? base_manifest : composition.revision.apply_to(base_manifest)
        result = ExperimentResult.new(
          id: id, base_manifest: base_manifest, task: task, revisions: revisions,
          validations: reports, probes: probes, contrasts: contrasts,
          composition: composition, selected_manifest: selected_manifest,
          started_at: started_at, completed_at: Time.now.utc,
          scope: { tenant_key: context.tenant_key, account_id: context.to_h[:account_id] }
        )
        record_completion(result)
        result
      rescue StandardError => e
        emit("harness.experiment.completed", dims: { status: "error", error_class: e.class.name },
             measures: { repetitions: repetitions })
        raise
      end

      private

      def validate!
        unless validator.respond_to?(:validate)
          raise HarnessExperimentError, "candidate validator must respond to #validate"
        end
        unless task.safe_for_probe?
          raise HarnessExperimentError,
                "probe environment must be sandboxed, network-disabled and side-effect isolated"
        end
        unless Harness.secure_equal?(Harness.digest(task.output_contract),
                                     Harness.digest(base_manifest.output_contract))
          raise HarnessExperimentError, "task output contract must match the base manifest"
        end
        limit = Agentkit.config.harness.max_probe_repetitions
        unless repetitions.positive? && repetitions <= limit
          raise HarnessExperimentError, "probe repetitions must be between 1 and #{limit}"
        end
      end

      def propose
        request = snapshot(
          "experiment_id" => id, "base_manifest" => base_manifest.to_h,
          "base_manifest_digest" => base_manifest.digest, "task" => task.to_h,
          "candidate_scopes" => Revision::SCOPES, "goal_digest" => goal&.digest
        )
        raw = proposer.call(request)
        values = if raw.respond_to?(:to_h) && !raw.is_a?(Array)
                   Harness.stringify_keys(raw.to_h).fetch("candidates")
                 else
                   raw
                 end
        revisions = Array(values).map do |value|
          value.is_a?(Revision) ? value : Revision.from_h(value)
        end
        limit = Agentkit.config.harness.max_experiment_candidates
        if revisions.size > limit
          raise HarnessExperimentError, "#{revisions.size} candidates exceed experiment limit #{limit}"
        end
        duplicate_ids = revisions.group_by(&:id).select { |_, items| items.size > 1 }.keys
        raise HarnessExperimentError, "duplicate revision ids: #{duplicate_ids.join(', ')}" if duplicate_ids.any?

        revisions.freeze
      rescue KeyError => e
        raise HarnessExperimentError, "proposer returned malformed candidates: #{e.message}"
      end

      def execute_probes(valid_reports)
        probes = []
        repetitions.times do |offset|
          repetition = offset + 1
          probes << execute_probe(base_manifest, role: "baseline", repetition: repetition)
          valid_reports.each do |report|
            probes << execute_probe(
              report.candidate_manifest, role: "candidate", repetition: repetition,
              revision_id: report.revision.id
            )
          end
        end
        probes.freeze
      end

      def execute_probe(manifest, role:, repetition:, revision_id: nil)
        probe_id = [id, role, revision_id, "r#{repetition}"].compact.join(":")
        started_at = Time.now.utc
        request = snapshot(
          "probe_id" => probe_id, "role" => role, "revision_id" => revision_id,
          "repetition" => repetition, "manifest" => manifest.to_h,
          "manifest_digest" => manifest.digest, "task" => task.to_h
        )
        raw = executor.call(request)
        data = Harness.stringify_keys(raw.respond_to?(:to_h) ? raw.to_h : {})
        output_digest = data["output_digest"] || Harness.digest(
          DeclarativeData.normalize(
            data.fetch("output"), label: "probe output", error_class: HarnessExperimentError
          )
        )
        ProbeResult.new(
          id: probe_id, role: role, revision_id: revision_id, repetition: repetition,
          manifest_digest: manifest.digest, task_digest: task.digest,
          model_digest: task.model_digest, environment_digest: task.environment_digest,
          status: "ok", output_reference: data.fetch("output_reference"),
          output_digest: output_digest, observations: data["observations"] || [],
          metrics: data["metrics"] || {}, evidence_refs: data["evidence_refs"] || [],
          started_at: started_at, completed_at: Time.now.utc
        )
      rescue StandardError => e
        ProbeResult.new(
          id: probe_id, role: role, revision_id: revision_id, repetition: repetition,
          manifest_digest: manifest.digest, task_digest: task.digest,
          model_digest: task.model_digest, environment_digest: task.environment_digest,
          status: "error", observations: [], metrics: {},
          error: { "class" => e.class.name, "message_digest" => Harness.digest(e.message.to_s) },
          started_at: started_at, completed_at: Time.now.utc
        )
      end

      def build_contrasts(valid_reports, probes)
        baselines = probes.select { |probe| probe.role == "baseline" }
        valid_reports.map do |report|
          candidates = probes.select { |probe| probe.revision_id == report.revision.id }
          request = snapshot(
            "experiment_id" => id, "revision" => report.revision.to_h,
            "baseline_probes" => baselines.map(&:to_h),
            "candidate_probes" => candidates.map(&:to_h)
          )
          raw = contrastor.call(request)
          data = Harness.stringify_keys(raw.respond_to?(:to_h) ? raw.to_h : {})
          BehavioralContrast.new(
            id: data["id"] || "#{id}:#{report.revision.id}", revision: report.revision,
            baseline_probes: baselines, candidate_probes: candidates,
            summary: data.fetch("summary"), attributions: data.fetch("attributions")
          )
        rescue KeyError => e
          raise HarnessExperimentError,
                "contrastor returned malformed evidence for #{report.revision.id}: #{e.message}"
        end.freeze
      end

      def compose(revisions, reports, probes, contrasts)
        available = reports.map(&:evidence_ref) + probes.flat_map(&:evidence_refs) +
                    contrasts.map(&:evidence_ref)
        if reports.none?(&:valid?)
          evidence = reports.empty? ? ["proposal:none:#{id}"] : reports.map(&:evidence_ref)
          return Composition.new(
            action: Composition::KEEP_BASE, available_evidence: evidence,
            reasons: [{ summary: "no valid candidate was available", evidence_refs: evidence }]
          )
        end

        request = snapshot(
          "experiment_id" => id, "base_manifest_digest" => base_manifest.digest,
          "task_digest" => task.digest, "candidates" => revisions.map(&:to_h),
          "validations" => reports.map(&:to_h), "probes" => probes.map(&:to_h),
          "contrasts" => contrasts.map(&:to_h), "allowed_actions" => Composition::ACTIONS
        )
        raw = composer.call(request)
        data = Harness.stringify_keys(raw.respond_to?(:to_h) ? raw.to_h : {})
        action = data.fetch("action").to_s.downcase
        action = Composition::KEEP_BASE if action == "keep_base"
        revision = resolve_composition_revision(action, data, reports)
        Composition.new(
          action: action, revision: revision, reasons: data.fetch("reasons"),
          available_evidence: available
        )
      rescue KeyError => e
        raise HarnessExperimentError, "composer returned malformed decision: #{e.message}"
      end

      def resolve_composition_revision(action, data, reports)
        return nil if action == Composition::KEEP_BASE

        if action == "adopt"
          revision_id = data.fetch("revision_id").to_s
          report = reports.find { |item| item.revision.id == revision_id }
          unless report&.valid?
            raise HarnessExperimentError, "composer selected invalid or unknown revision #{revision_id.inspect}"
          end
          return report.revision
        end

        raise HarnessExperimentError, "unknown composition action #{action.inspect}" unless action == "compose"

        revision = data.fetch("revision")
        revision = revision.is_a?(Revision) ? revision : Revision.from_h(revision)
        report = validator.validate(base: base_manifest, revision: revision, goal: goal)
        unless report.valid?
          messages = report.errors.map(&:message).join("; ")
          raise HarnessCandidateInvalid, "composed revision is invalid: #{messages}"
        end
        revision
      end

      def record_completion(result)
        emit(
          "harness.experiment.completed", dims: { status: "ok", action: result.composition.action },
          measures: {
            candidates: result.revisions.size, valid_candidates: result.validations.count(&:valid?),
            probes: result.probes.size, contrasts: result.contrasts.size,
            confounded_changes: result.contrasts.sum do |contrast|
              contrast.attributions.count { |item| item.verdict == "confounded" }
            end
          }
        )
        Agentkit.with_context(context) do
          Audit.record(
            event_type: "harness.experiment.completed", agent_name: "Agentkit::Harness::Experiment",
            status: result.composition.action,
            payload: {
              experiment_id: id, result_digest: result.digest,
              base_manifest_digest: base_manifest.digest,
              selected_manifest_digest: result.selected_manifest.digest,
              task_digest: task.digest, candidate_count: result.revisions.size,
              valid_candidate_count: result.validations.count(&:valid?),
              probe_count: result.probes.size, contrast_count: result.contrasts.size,
              action: result.composition.action,
              selected_revision_digest: result.selected_revision&.digest
            }.compact,
            context: context
          )
        end
      end

      def emit(name, dims: {}, measures: {})
        Agentkit.with_context(context) { Telemetry.emit(name, dims: dims, measures: measures) }
      end

      def snapshot(value)
        Harness.deep_freeze(Harness.stringify_keys(value))
      end

      def callable!(value, label)
        return value if value.respond_to?(:call)

        raise HarnessExperimentError, "#{label} must respond to #call"
      end

      def integer_repetitions(value)
        Integer(value)
      rescue ArgumentError, TypeError
        raise HarnessExperimentError, "probe repetitions must be a positive integer"
      end
    end
  end
end
