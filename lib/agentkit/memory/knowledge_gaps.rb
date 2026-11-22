# frozen_string_literal: true

module Agentkit
  module Memory
    # Structured, opt-in flagging for missing, stale, or contradictory
    # operational knowledge discovered during agent execution.
    #
    # Gaps are stored under the Imagination Firewall (ontological: :imagined)
    # and tagged as untrusted claims. Flagging a gap never mutates skills,
    # wikis, or verified memory; an offline curator and an independent human
    # reviewer must verify and resolve it.
    module KnowledgeGaps
      MEMORY_TYPE = "knowledge_gap"
      KINDS = %w[missing stale contradiction].freeze
      STATUSES = %w[open resolved dismissed].freeze
      MAX_SUBJECT_BYTES = 128
      MAX_TEXT_BYTES = 1_024
      MAX_EVIDENCE_REFS = 20

      module_function

      def flag(kind:, subject:, summary:, suggested_update: nil, evidence_refs: [],
               source_agent: nil, context: Context.resolve)
        scope = require_scope!(context)
        normalized_kind = kind.to_s
        raise ArgumentError, "kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(normalized_kind)

        topic = subject!(subject)
        text = bounded!(summary, label: "summary")
        suggestion = suggested_update.nil? ? nil : bounded!(suggested_update, label: "suggested_update")
        refs = Array(evidence_refs).map { |r| r.to_s.strip }.reject(&:empty?).uniq.first(MAX_EVIDENCE_REFS)
        reporter = context.principal.to_s

        record = within(context) do
          Memory.store(
            text,
            type: MEMORY_TYPE,
            source_agent: (source_agent || context.loop_state&.dig(:agent) || "Agentkit::Memory::KnowledgeGaps").to_s,
            tags: ["knowledge_gap", "kind:#{normalized_kind}", "subject:#{topic}", "status:open"],
            retention: :durable,
            embed: false,
            ontological_type: "imagined",
            metadata: {
              "kind" => normalized_kind,
              "subject" => topic,
              "status" => "open",
              "untrusted_claim" => true,
              "reported_by" => reporter,
              "suggested_update" => suggestion,
              "evidence_refs" => refs,
              "tainted_context" => context.loop_state&.dig(:tainted) == true,
              "tenant_key" => scope.tenant_key,
              "account_id" => scope.account_id
            }.compact,
            context: context
          )
        end
        raise HarnessPersistenceError, "knowledge gap was not saved" unless record

        Audit.record(
          event_type: "knowledge_gap.flagged",
          agent_name: record.source_agent,
          context: context,
          payload: { gap_id: record.id, kind: normalized_kind, subject: topic }
        )
        Telemetry.emit(
          "knowledge_gap.flagged",
          dims: { kind: normalized_kind, subject: topic },
          measures: { count: 1 }
        )

        receipt(record)
      end

      def list(status: "open", kind: nil, subject: nil, limit: 50, context: Context.resolve)
        scope = Scope.resolve(context: context)
        if status && !STATUSES.include?(status.to_s)
          raise ArgumentError, "status must be one of #{STATUSES.join(', ')}"
        end
        if kind && !KINDS.include?(kind.to_s)
          raise ArgumentError, "kind must be one of #{KINDS.join(', ')}"
        end

        rows = within(context) do
          Memory.all(types: [MEMORY_TYPE], ontological: :imagined).select do |row|
            row.active? && row.available? && scope.match?(row) &&
              (status.nil? || row.metadata["status"] == status.to_s) &&
              (kind.nil? || row.metadata["kind"] == kind.to_s) &&
              (subject.nil? || row.metadata["subject"] == subject.to_s)
          end
        end
        rows.sort_by { |row| -row.created_at.to_f }.first(Integer(limit))
      end

      def resolve!(id:, actor:, authorize:, resolution:, status: "resolved", context: Context.resolve)
        scope = Scope.resolve(context: context)
        reviewer = actor.to_s.strip
        raise ArgumentError, "reviewer actor is required" if reviewer.empty?
        unless %w[resolved dismissed].include?(status.to_s)
          raise ArgumentError, "resolution status must be resolved or dismissed"
        end
        note = bounded!(resolution, label: "resolution")

        existing = list(status: "open", limit: 500, context: context).find { |row| row.id.to_s == id.to_s }
        raise ConfigurationError, "open knowledge gap #{id} not found" unless existing
        if existing.metadata["reported_by"].to_s == reviewer
          raise ConfigurationError, "knowledge gap reporter cannot resolve their own gap"
        end
        unless authorize.call(existing, reviewer, context) == true
          raise ConfigurationError, "knowledge gap resolution denied"
        end

        updated = within(context) do
          record = Memory.store(
            existing.content,
            type: MEMORY_TYPE,
            source_agent: existing.source_agent,
            tags: ["knowledge_gap", "kind:#{existing.metadata['kind']}", "subject:#{existing.metadata['subject']}", "status:#{status}"],
            retention: :durable,
            embed: false,
            ontological_type: "imagined",
            metadata: existing.metadata.merge(
              "status" => status.to_s,
              "resolved_by" => reviewer,
              "resolution" => note,
              "resolved_at" => Time.now.utc.iso8601(6),
              "previous_gap_id" => existing.id,
              "tenant_key" => scope.tenant_key,
              "account_id" => scope.account_id
            ).compact,
            context: context
          )
          raise HarnessPersistenceError, "resolved knowledge gap was not saved" unless record
          Memory.supersede!([existing], by: record, context: context)
          record
        end

        Audit.record(
          event_type: "knowledge_gap.#{status}",
          context: context,
          payload: { gap_id: updated.id, previous_gap_id: existing.id, subject: updated.metadata["subject"] }
        )
        receipt(updated)
      end

      # Ready-to-use ToolContract for opt-in use inside AgentLoop.
      # Advisory/observational only: records an untrusted gap claim without
      # mutating skills, wikis, or operational records.
      def tool(name: :flag_knowledge_gap)
        ToolContract.new(
          name: name,
          description: "Flag missing, stale, or contradictory company knowledge for offline curation and human review.",
          input_schema: {
            type: "object",
            additionalProperties: false,
            required: %w[kind subject summary],
            properties: {
              kind: { type: "string", enum: KINDS },
              subject: { type: "string" },
              summary: { type: "string" },
              suggested_update: { type: "string" },
              evidence_refs: { type: "array", items: { type: "string" } }
            }
          },
          risk: :read,
          effect: :read_only,
          callable: lambda { |kind:, subject:, summary:, suggested_update: nil, evidence_refs: []|
            flag(
              kind: kind,
              subject: subject,
              summary: summary,
              suggested_update: suggested_update,
              evidence_refs: evidence_refs,
              context: Context.resolve
            )
          }
        )
      end

      def receipt(record)
        Harness.deep_freeze(
          "id" => record.id,
          "kind" => record.metadata["kind"],
          "subject" => record.metadata["subject"],
          "status" => record.metadata["status"],
          "untrusted_claim" => true,
          "authorizes" => false
        )
      end

      def require_scope!(context)
        scope = Scope.resolve(context: context)
        if context.principal.to_s.strip.empty?
          raise ConfigurationError, "knowledge gap flagging requires an authenticated principal"
        end
        scope
      end

      def subject!(value)
        text = value.to_s.strip
        unless text.bytesize.between?(1, MAX_SUBJECT_BYTES) && text.match?(/\A[a-zA-Z0-9:._\/-]+\z/)
          raise ArgumentError, "subject must contain 1..#{MAX_SUBJECT_BYTES} safe bytes"
        end
        text
      end

      def bounded!(value, label:)
        text = value.to_s.strip
        raise ArgumentError, "#{label} must be 1..#{MAX_TEXT_BYTES} bytes" unless text.bytesize.between?(1, MAX_TEXT_BYTES)
        text
      end

      def within(context, &block) = Agentkit.with_context(context, &block)
    end
  end
end
