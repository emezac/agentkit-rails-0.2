# frozen_string_literal: true

module Agentkit
  module Memory
    # Explicit, keyword-only continuity. No model calls, vectors or raw tool
    # transcripts are required. The host supplies trusted task IDs and decides
    # when recording a user prompt is appropriate.
    module Continuity
      MAX_TEXT_BYTES = 1_024
      MAX_ID_BYTES = 128
      module_function

      def checkpoint(task_id:, summary:, turn:, transcript_digest:, evidence_refs: [], context: Context.resolve)
        require_task_scope!(context)
        id = identifier!(task_id)
        text = bounded!(summary)
        within(context) do
          previous = latest(task_id: id, context: context)
          record = Memory.store(text, type: "agent_task_note", source_agent: "Agentkit::AgentLoop",
            tags: ["continuity", "task", "task:#{id}", owner_tag(context)], retention: :durable, embed: false,
            metadata: { "task_id" => id, "owner" => owner(context), "turn" => Integer(turn),
                        "transcript_digest" => transcript_digest.to_s,
                        "evidence_refs" => Array(evidence_refs).first(20).map(&:to_s) }, context: context)
          raise HarnessPersistenceError, "continuity checkpoint was not saved" unless record
          Memory.supersede!([previous], by: record, context: context) if previous
          record
        end
      end

      def latest(task_id:, context: Context.resolve)
        require_task_scope!(context)
        id = identifier!(task_id)
        within(context) do
          Memory.all(types: ["agent_task_note"], tags: ["task:#{id}", owner_tag(context)]).select { |row| row.active? &&
            row.metadata["task_id"] == id && row.metadata["owner"] == owner(context) &&
            row.available? }.max_by(&:created_at)
        end
      end

      def record_episode(task_id:, summary:, outcome:, context: Context.resolve)
        require_task_scope!(context)
        id = identifier!(task_id)
        text = bounded!(summary)
        within(context) do
          Memory.store(text, type: "agent_episode", source_agent: "Agentkit::AgentLoop",
            tags: ["continuity", "episode", owner_tag(context)], retention: :standard, embed: false,
            metadata: { "task_id" => id, "owner" => owner(context), "stop_reason" => outcome.stop_reason,
                        "turns" => outcome.turns, "transcript_digest" => outcome.transcript_digest,
                        "evidence_refs" => outcome.evidence_refs.first(20) }, context: context)
        end
      end

      def search_episodes(query, k: 5, context: Context.resolve)
        require_task_scope!(context)
        within(context) do
          Memory.recall(query, k: k, types: ["agent_episode"], tags: [owner_tag(context)],
                        mode: :keyword, embed_query: false, context: context)
        end
      end

      def remember_fact(subject:, key:, content:, context: Context.resolve)
        kind = subject.to_sym
        raise ArgumentError, "subject must be :user or :project" unless %i[user project].include?(kind)
        raise ConfigurationError, "user context required" if kind == :user && context.user.nil?
        require_project_scope!(context) if kind == :project
        fact_key = identifier!(key)
        text = bounded!(content)
        within(context) do
          previous = facts(subject: kind, context: context).select { |row| row.metadata["fact_key"] == fact_key }
          row = Memory.store(text, type: "profile_fact", source_agent: "Agentkit::Memory::Continuity",
            tags: ["profile", kind.to_s], retention: :durable, embed: false,
            metadata: { "subject" => kind.to_s, "fact_key" => fact_key }, context: context)
          raise HarnessPersistenceError, "profile fact was not saved" unless row
          Memory.supersede!(previous, by: row, context: context) if previous.any?
          row
        end
      end

      def facts(subject:, query: nil, k: 5, context: Context.resolve)
        kind = subject.to_sym
        raise ArgumentError, "subject must be :user or :project" unless %i[user project].include?(kind)
        raise ConfigurationError, "user context required" if kind == :user && context.user.nil?
        require_project_scope!(context) if kind == :project
        within(context) do
          scope = { types: ["profile_fact"] }
          scope[:user_id] = id_of(context.user) if kind == :user
          rows = Memory.all(scope).select { |row| row.available? &&
            row.metadata["subject"] == kind.to_s }
          terms = query.to_s.downcase.scan(/[[:alnum:]]{2,}/)
          rows = rows.select { |row| terms.empty? || terms.any? { |term|
            row.content.downcase.include?(term) || row.metadata["fact_key"].to_s.include?(term) } }
          rows.sort_by { |row| [-row.importance.to_f, -row.created_at.to_f] }.first(Integer(k))
        end
      end

      def identifier!(value)
        id = value.to_s
        raise ArgumentError, "identifier must contain 1..#{MAX_ID_BYTES} safe bytes" unless
          id.bytesize.between?(1, MAX_ID_BYTES) && id.match?(/\A[a-zA-Z0-9:._-]+\z/)
        id
      end

      def bounded!(value)
        text = value.to_s.strip
        raise ArgumentError, "continuity text must contain 1..#{MAX_TEXT_BYTES} bytes" unless
          text.bytesize.between?(1, MAX_TEXT_BYTES)
        text
      end

      def within(context, &block) = Agentkit.with_context(context, &block)
      def require_task_scope!(context)
        raise ConfigurationError, "authenticated principal required" if context.principal.to_s.empty?
        require_project_scope!(context)
      end
      def require_project_scope!(context)
        raise ConfigurationError, "project scope required" if context.tenant_key.nil? && context.account.nil?
      end
      def id_of(value) = value.respond_to?(:id) ? value.id : value
      def owner(context) = context.principal.to_s
      def owner_tag(context) = "owner:#{Digest::SHA256.hexdigest(owner(context))[0, 16]}"
    end
  end
end
