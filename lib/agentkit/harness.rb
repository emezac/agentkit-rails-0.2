# frozen_string_literal: true

require "time"

module Agentkit
  # Durable control plane for long-running agent work.
  #
  # A model saying "done" is not a completion condition. A Harness::Progress
  # becomes complete only when every required criterion has verified evidence
  # and every required output has a recorded reference. Checkpoints reuse the
  # existing scoped Memory store and supersede non-destructively.
  module Harness
    MEMORY_TYPE = "harness_checkpoint"
    SCHEMA_VERSION = 2
    SUPPORTED_SCHEMA_VERSIONS = [1, SCHEMA_VERSION].freeze
    VERDICTS = %w[verified failed unresolved].freeze
    STATUSES = %w[pending running blocked completed failed].freeze
    ACTIVE_MEMORY_STATUSES = %w[raw embedded consolidated].freeze
    RecoveryPolicy = Agentkit::RecoveryPolicy

    class Criterion
      attr_reader :id, :description, :required

      def initialize(id:, description:, required: true)
        @id = required_text(id, :id).freeze
        @description = required_text(description, :description).freeze
        @required = !!required
        freeze
      end

      def required? = required
      def to_h = { "id" => id, "description" => description, "required" => required }

      private

      def required_text(value, name)
        text = value.to_s.strip
        raise ArgumentError, "criterion #{name} is required" if text.empty?

        text
      end
    end

    # A constraint is an independently verifiable boundary, not prose hidden in
    # the objective. `kind: :must_not` is useful for protected side effects.
    class Constraint < Criterion
      KINDS = %w[must must_not].freeze
      attr_reader :kind

      def initialize(id:, description:, required: true, kind: :must)
        @kind = kind.to_s
        raise ArgumentError, "unknown constraint kind: #{@kind.inspect}" unless KINDS.include?(@kind)

        super(id: id, description: description, required: required)
      end

      def to_h = super.merge("kind" => kind)
    end

    class Goal
      attr_reader :id, :objective, :criteria, :constraints, :scope,
                  :protected_resources, :required_approvals, :required_outputs,
                  :max_steps, :metadata

      def initialize(objective:, criteria:, constraints: [], scope: {}, protected_resources: [],
                     required_approvals: nil, approvals: nil, required_outputs: [],
                     id: nil, max_steps: nil, metadata: {})
        @id = (id || SecureRandom.uuid).to_s.strip.freeze
        @objective = objective.to_s.strip.freeze
        @criteria = normalize_criteria(criteria)
        @constraints = normalize_constraints(constraints)
        @scope = normalize_scope(scope)
        @protected_resources = normalize_names(protected_resources)
        approval_values = required_approvals.nil? ? approvals : required_approvals
        @required_approvals = normalize_names(approval_values || [])
        @required_outputs = Array(required_outputs).map { |name| name.to_s.strip.freeze }
                                                   .reject(&:empty?).uniq.freeze
        @max_steps = Integer(max_steps || Agentkit.config.harness.max_steps)
        @metadata = Harness.deep_freeze(Harness.stringify_keys(metadata || {}))
        validate!
        freeze
      end

      def criterion(id) = criteria.find { |item| item.id == id.to_s }
      def constraint(id) = constraints.find { |item| item.id == id.to_s }
      def requirement(id) = criterion(id) || constraint(id)

      def approval_required_for?(name)
        value = name.to_s
        required_approvals.any? do |pattern|
          pattern == value || (pattern.end_with?("*") && value.start_with?(pattern.delete_suffix("*")))
        end
      end

      def to_h
        {
          "id" => id,
          "objective" => objective,
          "criteria" => criteria.map(&:to_h),
          "constraints" => constraints.map(&:to_h),
          "scope" => scope,
          "protected_resources" => protected_resources,
          "required_approvals" => required_approvals,
          "required_outputs" => required_outputs,
          "max_steps" => max_steps,
          "metadata" => metadata
        }
      end

      def digest = Harness.digest(to_h)

      def self.from_h(value)
        data = Harness.stringify_keys(value)
        new(
          id: data.fetch("id"), objective: data.fetch("objective"),
          criteria: data.fetch("criteria"), required_outputs: data["required_outputs"] || [],
          constraints: data["constraints"] || [], scope: data["scope"] || {},
          protected_resources: data["protected_resources"] || [],
          required_approvals: data["required_approvals"] || [],
          max_steps: data.fetch("max_steps"), metadata: data["metadata"] || {}
        )
      end

      private

      def normalize_criteria(items)
        Array(items).map.with_index do |item, index|
          if item.is_a?(Criterion)
            item
          elsif item.respond_to?(:to_h)
            data = Harness.stringify_keys(item.to_h)
            Criterion.new(
              id: data["id"] || "criterion_#{index + 1}",
              description: data["description"] || data["text"],
              required: data.fetch("required", true)
            )
          else
            Criterion.new(id: "criterion_#{index + 1}", description: item)
          end
        end.freeze
      end

      def normalize_constraints(items)
        Array(items).map.with_index do |item, index|
          if item.is_a?(Constraint)
            item
          elsif item.respond_to?(:to_h)
            data = Harness.stringify_keys(item.to_h)
            Constraint.new(
              id: data["id"] || "constraint_#{index + 1}",
              description: data["description"] || data["text"],
              required: data.fetch("required", true), kind: data.fetch("kind", "must")
            )
          else
            Constraint.new(id: "constraint_#{index + 1}", description: item)
          end
        end.freeze
      end

      def normalize_scope(value)
        data = Harness.stringify_keys(value || {})
        normalized = {
          "include" => normalize_names(data["include"] || []),
          "exclude" => normalize_names(data["exclude"] || [])
        }
        normalized["metadata"] = Harness.stringify_keys(data["metadata"]) if data["metadata"]
        Harness.deep_freeze(normalized)
      end

      def normalize_names(items)
        Array(items).map { |item| item.to_s.strip }.reject(&:empty?).uniq.freeze
      end

      def validate!
        raise ArgumentError, "goal id is required" if id.empty?
        raise ArgumentError, "goal objective is required" if objective.empty?
        if criteria.empty? && constraints.empty? && required_outputs.empty?
          raise ArgumentError, "goal requires at least one criterion, constraint or required output"
        end
        duplicates = (criteria + constraints).group_by(&:id).select { |_, values| values.size > 1 }.keys
        raise ArgumentError, "duplicate requirement ids: #{duplicates.join(', ')}" if duplicates.any?
        overlap = scope["include"] & scope["exclude"]
        raise ArgumentError, "scope entries cannot be both included and excluded: #{overlap.join(', ')}" if overlap.any?
        raise ArgumentError, "goal max_steps must be positive" unless max_steps.positive?

        JSON.generate(to_h)
      rescue JSON::GeneratorError => e
        raise ArgumentError, "goal must be JSON serializable: #{e.message}"
      end
    end

    class Evidence
      attr_reader :criterion_id, :verdict, :source, :summary, :digest, :checked_at

      def initialize(criterion_id:, verdict:, source: nil, summary: nil, value: nil,
                     digest: nil, checked_at: Time.now.utc)
        @criterion_id = criterion_id.to_s.strip.freeze
        @verdict = verdict.to_s.freeze
        @source = source&.to_s&.freeze
        @summary = summary&.to_s&.freeze
        @checked_at = Harness.time(checked_at)
        validate!
        @digest = Harness.valid_digest!(
          digest || Harness.digest(value.nil? ? { source: @source, summary: @summary } : value)
        ).freeze
        freeze
      end

      def verified? = verdict == "verified"

      def to_h
        {
          "criterion_id" => criterion_id, "verdict" => verdict, "source" => source,
          "summary" => summary, "digest" => digest, "checked_at" => checked_at.iso8601(6)
        }.compact
      end

      def self.from_h(value)
        data = Harness.stringify_keys(value)
        new(
          criterion_id: data.fetch("criterion_id"), verdict: data.fetch("verdict"),
          source: data["source"], summary: data["summary"], digest: data.fetch("digest"),
          checked_at: data.fetch("checked_at")
        )
      end

      private

      def validate!
        raise ArgumentError, "evidence criterion_id is required" if criterion_id.empty?
        raise ArgumentError, "unknown evidence verdict: #{verdict.inspect}" unless VERDICTS.include?(verdict)
        if %w[verified failed].include?(verdict) && source.to_s.strip.empty?
          raise ArgumentError, "evidence source is required for #{verdict} verdicts"
        end
      end
    end

    Evaluation = Struct.new(
      :complete, :status, :missing_criteria, :failed_criteria, :unresolved_criteria,
      :missing_constraints, :failed_constraints, :unresolved_constraints,
      :missing_outputs, :missing_approvals, :step_count, :max_steps,
      keyword_init: true
    ) do
      def complete? = !!complete

      def to_h
        {
          complete: complete?, status: status, missing_criteria: missing_criteria,
          failed_criteria: failed_criteria, unresolved_criteria: unresolved_criteria,
          missing_constraints: missing_constraints, failed_constraints: failed_constraints,
          unresolved_constraints: unresolved_constraints,
          missing_outputs: missing_outputs, missing_approvals: missing_approvals,
          step_count: step_count, max_steps: max_steps
        }
      end
    end

    class Progress
      attr_reader :goal, :status, :step_count, :outputs, :evidence, :approvals, :decisions,
                  :lessons, :open_issues, :next_action, :created_at, :updated_at

      def initialize(goal:, status: "pending", step_count: 0, outputs: {}, evidence: {},
                     approvals: {}, decisions: [], lessons: [], open_issues: [], next_action: nil,
                     created_at: Time.now.utc, updated_at: Time.now.utc, telemetry_context: nil)
        @goal = goal.is_a?(Goal) ? goal : Goal.from_h(goal)
        @status = status.to_s
        @step_count = Integer(step_count)
        @outputs = Harness.stringify_keys(outputs || {})
        @evidence = normalize_evidence(evidence)
        @approvals = normalize_approvals(approvals)
        @decisions = normalize_log(decisions)
        @lessons = normalize_log(lessons)
        @open_issues = normalize_log(open_issues)
        @next_action = next_action&.to_s
        @created_at = Harness.time(created_at)
        @updated_at = Harness.time(updated_at)
        @telemetry_context = telemetry_context
        validate!
      end

      def start!
        ensure_mutable!
        @status = "running" if %w[pending blocked].include?(status)
        touch!
      end

      def advance!(next_action: nil)
        ensure_mutable!
        if step_count >= goal.max_steps
          @status = "blocked"
          @next_action = next_action&.to_s
          add_log(@open_issues, "step budget exhausted", source: "harness")
          touch!
          raise BudgetExceeded.new(resource: :harness_steps, limit: goal.max_steps, used: step_count)
        end

        @status = "running"
        @step_count += 1
        @next_action = next_action&.to_s
        touch!
      end

      # Store only a reference and a digest. `value` participates in the digest
      # but is intentionally discarded so a checkpoint cannot become a secret
      # or artifact dump.
      def record_output(name, reference:, value: nil, digest: nil)
        ensure_mutable!
        key = required_text(name, "output name")
        ref = required_text(reference, "output reference")
        @outputs[key] = {
          "reference" => ref,
          "digest" => Harness.valid_digest!(digest || Harness.digest(value.nil? ? ref : value)),
          "recorded_at" => Time.now.utc.iso8601(6)
        }
        @status = "running" if @status == "pending"
        touch!
      end

      def record_evidence(criterion:, verdict:, source: nil, summary: nil, value: nil, digest: nil)
        ensure_mutable!
        criterion_id = criterion.to_s
        unless goal.requirement(criterion_id)
          raise ArgumentError, "unknown goal criterion or constraint: #{criterion_id.inspect}"
        end

        item = Evidence.new(
          criterion_id: criterion_id, verdict: verdict, source: source,
          summary: summary, value: value, digest: digest
        )
        @evidence[criterion_id] = item
        @status = "running" if @status == "pending"
        touch!
      end

      def record_approval(name, status: :approved, actor: nil, evidence_ref: nil, value: nil, digest: nil)
        ensure_mutable!
        key = required_text(name, "approval name")
        state = status.to_s
        raise ArgumentError, "approval status must be approved, rejected or pending" unless
          %w[approved rejected pending].include?(state)
        if state == "approved" && evidence_ref.to_s.strip.empty?
          raise ArgumentError, "approved approval requires an evidence reference"
        end

        @approvals[key] = {
          "name" => key, "status" => state, "actor" => actor&.to_s,
          "evidence_ref" => evidence_ref&.to_s,
          "evidence_digest" => Harness.valid_digest!(
            digest || Harness.digest(value.nil? ? evidence_ref.to_s : value)
          ),
          "recorded_at" => Time.now.utc.iso8601(6)
        }.compact
        @status = "running" if @status == "pending"
        touch!
      end

      def record_decision(summary, source: nil)
        ensure_mutable!
        add_log(@decisions, required_text(summary, "decision"), source: source)
        touch!
      end

      def record_lesson(summary, source: nil)
        ensure_mutable!
        add_log(@lessons, required_text(summary, "lesson"), source: source)
        touch!
      end

      def add_issue(summary, source: nil)
        ensure_mutable!
        add_log(@open_issues, required_text(summary, "issue"), source: source)
        touch!
      end

      def next_action=(value)
        ensure_mutable!
        @next_action = value&.to_s
        touch!
      end

      def block!(reason:, next_action: nil)
        ensure_mutable!
        add_issue(reason, source: "harness")
        @status = "blocked"
        @next_action = next_action&.to_s
        touch!
      end

      def fail!(reason:)
        ensure_mutable!
        add_issue(reason, source: "harness")
        @status = "failed"
        @next_action = nil
        touch!
      end

      def evaluate!
        required = goal.criteria.select(&:required?)
        required_constraints = goal.constraints.select(&:required?)
        missing = missing_ids(required)
        failed = verdict_ids(required, "failed")
        unresolved = verdict_ids(required, "unresolved")
        missing_constraints = missing_ids(required_constraints)
        failed_constraints = verdict_ids(required_constraints, "failed")
        unresolved_constraints = verdict_ids(required_constraints, "unresolved")
        unverified = (required + required_constraints).reject do |requirement|
          evidence[requirement.id]&.verified?
        end.map(&:id)
        missing_outputs = goal.required_outputs.reject { |name| outputs.key?(name) }
        missing_approvals = goal.required_approvals.reject { |name| approval_satisfied?(name) }
        gates_satisfied = unverified.empty? && missing_outputs.empty? && missing_approvals.empty?
        complete = gates_satisfied && status != "failed"

        if complete
          prior_status = @status
          @status = "completed"
          @next_action = nil
          touch!
          if prior_status != "completed"
            Agentkit.with_context(@telemetry_context || Context.resolve) do
              Telemetry.emit(
                "harness.run.completed", dims: { goal_id: goal.id, status: status },
                measures: {
                  steps: step_count,
                  duration_ms: ((updated_at - created_at) * 1000).round,
                  first_pass: step_count <= 1
                }
              )
            end
          end
        end

        Evaluation.new(
          complete: complete, status: status, missing_criteria: missing,
          failed_criteria: failed, unresolved_criteria: unresolved,
          missing_constraints: missing_constraints,
          failed_constraints: failed_constraints,
          unresolved_constraints: unresolved_constraints,
          missing_outputs: missing_outputs, missing_approvals: missing_approvals,
          step_count: step_count, max_steps: goal.max_steps
        )
      end

      def complete!
        report = evaluate!
        return report if report.complete?

        raise HarnessIncomplete,
              "goal #{goal.id.inspect} is incomplete: " \
              "missing criteria=#{report.missing_criteria.inspect}, " \
              "failed=#{report.failed_criteria.inspect}, " \
              "unresolved=#{report.unresolved_criteria.inspect}, " \
              "missing constraints=#{report.missing_constraints.inspect}, " \
              "failed constraints=#{report.failed_constraints.inspect}, " \
              "unresolved constraints=#{report.unresolved_constraints.inspect}, " \
              "missing outputs=#{report.missing_outputs.inspect}, " \
              "missing approvals=#{report.missing_approvals.inspect}"
      end

      def complete? = status == "completed"

      def context_fragment(max_bytes: Agentkit.config.harness.max_context_bytes)
        lines = [
          "## Goal Contract",
          "Goal ID: #{goal.id}",
          "Objective: #{goal.objective}",
          "Status: #{status}; steps: #{step_count}/#{goal.max_steps}",
          "Acceptance criteria:"
        ]
        goal.criteria.each do |criterion|
          result = evidence[criterion.id]
          lines << "- [#{result&.verdict || 'missing'}] #{criterion.id}: #{criterion.description}"
        end
        if goal.constraints.any?
          lines << "Constraints:"
          goal.constraints.each do |constraint|
            result = evidence[constraint.id]
            lines << "- [#{result&.verdict || 'missing'}] #{constraint.id} (#{constraint.kind}): #{constraint.description}"
          end
        end
        lines << "Scope include: #{goal.scope['include'].join(', ')}" if goal.scope["include"].any?
        lines << "Scope exclude: #{goal.scope['exclude'].join(', ')}" if goal.scope["exclude"].any?
        lines << "Protected resources: #{goal.protected_resources.join(', ')}" if goal.protected_resources.any?
        lines << "Required approvals: #{goal.required_approvals.join(', ')}" if goal.required_approvals.any?
        lines << "Recorded approvals: #{approvals.keys.join(', ')}" if approvals.any?
        lines << "Required outputs: #{goal.required_outputs.join(', ')}" if goal.required_outputs.any?
        lines << "Recorded outputs: #{outputs.keys.join(', ')}" if outputs.any?
        lines << "Open issues: #{open_issues.map { |item| item['summary'] }.join(' | ')}" if open_issues.any?
        lines << "Lessons: #{lessons.map { |item| item['summary'] }.join(' | ')}" if lessons.any?
        lines << "Next action: #{next_action}" unless next_action.to_s.empty?
        Harness.truncate(lines.join("\n"), Integer(max_bytes))
      end

      def to_h
        {
          "schema_version" => SCHEMA_VERSION,
          "goal" => goal.to_h,
          "goal_digest" => goal.digest,
          "status" => status,
          "step_count" => step_count,
          "outputs" => outputs,
          "evidence" => evidence.transform_values(&:to_h),
          "approvals" => approvals,
          "decisions" => decisions,
          "lessons" => lessons,
          "open_issues" => open_issues,
          "next_action" => next_action,
          "created_at" => created_at.iso8601(6),
          "updated_at" => updated_at.iso8601(6)
        }
      end

      def self.from_h(value, context: nil)
        data = Harness.stringify_keys(value)
        version = data["schema_version"].to_i
        raise HarnessIntegrityError, "unsupported harness schema version" unless
          SUPPORTED_SCHEMA_VERSIONS.include?(version)

        raw_goal = data.fetch("goal")
        goal = Goal.from_h(raw_goal)
        calculated_digest = version == 1 ? Harness.digest(raw_goal) : goal.digest
        raise HarnessIntegrityError, "goal digest mismatch" unless
          Harness.secure_equal?(data.fetch("goal_digest"), calculated_digest)

        new(
          goal: goal, status: data.fetch("status"), step_count: data.fetch("step_count"),
          outputs: data["outputs"] || {}, evidence: data["evidence"] || {},
          approvals: data["approvals"] || {},
          decisions: data["decisions"] || [], lessons: data["lessons"] || [],
          open_issues: data["open_issues"] || [],
          next_action: data["next_action"], created_at: data.fetch("created_at"),
          updated_at: data.fetch("updated_at"), telemetry_context: context
        )
      end

      private

      def normalize_evidence(items)
        Harness.stringify_keys(items || {}).to_h do |criterion_id, value|
          item = value.is_a?(Evidence) ? value : Evidence.from_h(value)
          raise ArgumentError, "evidence key does not match criterion" unless item.criterion_id == criterion_id

          [criterion_id, item]
        end
      end

      def normalize_log(items)
        Array(items).map { |item| Harness.stringify_keys(item) }
      end

      def normalize_approvals(items)
        Harness.stringify_keys(items || {}).each_with_object({}) do |(name, value), result|
          data = Harness.stringify_keys(value || {})
          raise ArgumentError, "approval key does not match name" if data["name"] && data["name"] != name
          state = data.fetch("status", "pending").to_s
          raise ArgumentError, "invalid approval status: #{state.inspect}" unless
            %w[approved rejected pending].include?(state)
          if state == "approved"
            raise ArgumentError, "approved approval requires an evidence reference" if
              data["evidence_ref"].to_s.strip.empty?
            raise ArgumentError, "approved approval requires an evidence digest" unless data["evidence_digest"]
          end
          Harness.valid_digest!(data.fetch("evidence_digest")) if data["evidence_digest"]
          result[name] = data.merge("name" => name, "status" => state)
        end
      end

      def add_log(target, summary, source: nil)
        target << {
          "summary" => summary.to_s,
          "source" => source&.to_s,
          "at" => Time.now.utc.iso8601(6)
        }.compact
        target.shift while target.size > Agentkit.config.harness.max_log_entries
      end

      def ensure_mutable!
        raise HarnessError, "completed harness progress is immutable" if status == "completed"
        raise HarnessError, "failed harness progress is immutable" if status == "failed"
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise ArgumentError, "#{label} is required" if text.empty?

        text
      end

      def touch!
        @updated_at = Time.now.utc
        self
      end

      def validate!
        raise ArgumentError, "unknown harness status: #{status.inspect}" unless STATUSES.include?(status)
        raise ArgumentError, "step_count cannot be negative" if step_count.negative?
        raise ArgumentError, "step_count exceeds goal max_steps" if step_count > goal.max_steps

        unknown = evidence.keys.reject { |id| goal.requirement(id) }
        raise ArgumentError, "evidence contains unknown requirements: #{unknown.join(', ')}" if unknown.any?
        if status == "completed" && !completion_gates_satisfied?
          raise HarnessIntegrityError, "completed harness progress does not satisfy its goal contract"
        end
      end

      def completion_gates_satisfied?
        (goal.criteria + goal.constraints).select(&:required?).all? do |requirement|
          evidence[requirement.id]&.verified?
        end &&
          goal.required_outputs.all? { |name| outputs.key?(name) } &&
          goal.required_approvals.all? { |name| approval_satisfied?(name) }
      end

      def approval_satisfied?(requirement)
        approvals.any? do |name, value|
          matches = name == requirement ||
                    (requirement.end_with?("*") && name.start_with?(requirement.delete_suffix("*")))
          matches && value["status"] == "approved"
        end
      end

      def missing_ids(requirements)
        requirements.reject { |requirement| evidence.key?(requirement.id) }.map(&:id)
      end

      def verdict_ids(requirements, verdict)
        requirements.select { |requirement| evidence[requirement.id]&.verdict == verdict }.map(&:id)
      end
    end

    class << self
      def define(**attributes) = Goal.new(**attributes)
      def start(goal, context: nil)
        ctx = context || Context.resolve
        progress = Progress.new(goal: goal, telemetry_context: ctx).start!
        Agentkit.with_context(ctx) do
          Telemetry.emit(
            "harness.run.started", dims: { goal_id: progress.goal.id },
            measures: {
              criteria: progress.goal.criteria.size,
              constraints: progress.goal.constraints.size,
              outputs: progress.goal.required_outputs.size
            }
          )
        end
        progress
      end

      def checkpoint!(progress, context: nil)
        raise ArgumentError, "progress must be an Agentkit::Harness::Progress" unless progress.is_a?(Progress)

        ctx = context || Context.resolve
        progress.evaluate!
        payload = progress.to_h
        encoded = JSON.generate(payload)
        limit = Agentkit.config.harness.max_checkpoint_bytes
        if encoded.bytesize > limit
          raise HarnessPersistenceError,
                "harness checkpoint is #{encoded.bytesize} bytes; configured limit is #{limit}"
        end

        previous = checkpoints(progress.goal.id, context: ctx).last
        checkpoint_digest = digest(payload)
        record = Memory.store(
          "Harness checkpoint #{progress.goal.id} status=#{progress.status} step=#{progress.step_count}",
          source_agent: "Agentkit::Harness", type: MEMORY_TYPE,
          tags: ["harness", goal_tag(progress.goal.id)], confidence: 1.0, importance: 0.9,
          retention: Agentkit.config.harness.checkpoint_retention, embed: false,
          metadata: {
            "schema_version" => SCHEMA_VERSION,
            "goal_id" => progress.goal.id,
            "checkpoint_digest" => checkpoint_digest,
            "progress" => payload
          },
          context: ctx
        )
        raise HarnessPersistenceError, "memory writes are disabled; harness checkpoint was not saved" if record.nil?

        Memory.supersede!([previous], by: record, context: ctx) if previous
        Audit.record(
          event_type: "harness.checkpoint", agent_name: "Agentkit::Harness",
          status: progress.status,
          payload: {
            goal_id: progress.goal.id, checkpoint_id: record.id,
            checkpoint_digest: checkpoint_digest, step_count: progress.step_count,
            evidence_count: progress.evidence.size, output_count: progress.outputs.size
          },
          context: ctx
        )
        Telemetry.emit(
          "harness.checkpoint",
          dims: { status: progress.status },
          measures: { bytes: encoded.bytesize, steps: progress.step_count,
                      evidence: progress.evidence.size, outputs: progress.outputs.size }
        )
        record
      end

      def resume(goal_id, context: nil)
        ctx = context || Context.resolve
        record = checkpoints(goal_id, context: ctx).last
        return nil unless record

        metadata = stringify_keys(record.metadata || {})
        payload = metadata.fetch("progress")
        expected = metadata.fetch("checkpoint_digest")
        raise HarnessIntegrityError, "harness checkpoint digest mismatch for #{record.id}" unless
          secure_equal?(expected, digest(payload))
        raise HarnessIntegrityError, "harness checkpoint goal mismatch for #{record.id}" unless
          metadata["goal_id"].to_s == goal_id.to_s

        Progress.from_h(payload, context: ctx)
      rescue KeyError => e
        raise HarnessIntegrityError, "malformed harness checkpoint: #{e.message}"
      end

      def checkpoints(goal_id, context: nil)
        ctx = context || Context.resolve
        rows = Agentkit.with_context(ctx) do
          Memory.all(
            types: [MEMORY_TYPE], tags: ["harness", goal_tag(goal_id)],
            status: ACTIVE_MEMORY_STATUSES
          )
        end
        rows.select do |record|
          data = stringify_keys(record.metadata || {})
          data["goal_id"].to_s == goal_id.to_s
        end.sort_by { |record| [record.created_at || Time.at(0), record.id.to_s] }
      end

      def digest(value)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
      rescue JSON::GeneratorError => e
        raise ArgumentError, "harness data must be JSON serializable: #{e.message}"
      end

      def secure_equal?(left, right)
        a = left.to_s
        b = right.to_s
        return false unless a.bytesize == b.bytesize

        a.bytes.zip(b.bytes).reduce(0) { |memo, (x, y)| memo | (x ^ y) }.zero?
      end

      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), out| out[key.to_s] = stringify_keys(item) }
        when Array
          value.map { |item| stringify_keys(item) }
        else
          value
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| key.freeze; deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        else
          value.freeze
        end
        value.freeze
      end

      def valid_digest!(value)
        text = value.to_s
        return text if text.match?(/\Asha256:[0-9a-f]{64}\z/)

        raise ArgumentError, "digest must be a sha256:<64 lowercase hex> value"
      end

      def canonical(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            [key, canonical(value[original])]
          end
        when Array
          value.map { |item| canonical(item) }
        when Time
          value.utc.iso8601(6)
        else
          value
        end
      end

      def time(value)
        parsed = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        parsed.utc
      rescue ArgumentError
        raise ArgumentError, "invalid harness timestamp: #{value.inspect}"
      end

      def truncate(text, max_bytes)
        raise ArgumentError, "max_bytes must be positive" unless max_bytes.positive?
        return text if text.bytesize <= max_bytes

        suffix = "\n… context truncated"
        return "" if suffix.bytesize > max_bytes

        body = text.dup
        body = body[0...-1] while body.bytesize + suffix.bytesize > max_bytes && !body.empty?
        body + suffix
      end

      private

      def goal_tag(goal_id)
        "goal:#{Digest::SHA256.hexdigest(goal_id.to_s)[0, 24]}"
      end
    end
  end
end
