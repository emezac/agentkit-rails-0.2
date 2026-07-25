# frozen_string_literal: true

module Agentkit
  # Assembles the system prompt under an explicit token budget.
  #
  # v0.1 concatenated identity + HITL rules + every recalled memory + domain
  # context with no limit and no ordering, so a long memory list could push the
  # actual instructions out of the model's attention — and the stable block was
  # not first, which defeats prompt caching.
  module ContextEngineer
    DEFAULT_BUDGET = 4_000 # tokens

    module_function

    def build(agent:, query: nil, memories: [], skills: [], extra: nil, budget: DEFAULT_BUDGET)
      cfg   = Agentkit.config
      ctx   = agent.respond_to?(:agent_context) ? agent.agent_context : Context.resolve
      parts = []

      # 1. Stable identity block first: it is identical across calls, which is
      #    what makes provider-side prompt caching actually hit.
      parts << [100, <<~IDENTITY]
        ## Agent Identity
        You are #{agent.class.name}, an AI agent running inside #{cfg.domain_name}.
        Primary domain entity: #{cfg.primary_entity}.
      IDENTITY

      parts << [95, "## Autonomy Level\n#{autonomy_text(cfg.hitl.level)}"]

      skills = SkillRegistry.compose(*skills) if skills.any? && skills.first.is_a?(Symbol)
      Array(skills).each { |s| parts << [80, s.system_prompt_fragment(ctx)] }

      domain = agent.respond_to?(:domain_context) ? agent.domain_context.to_s : ""
      parts << [70, "## Domain Context\n#{domain}"] unless domain.empty?

      Array(skills).each do |skill|
        skill.context_providers.each_value do |provider|
          value = safely { provider.call(ctx) }
          parts << [provider.priority, value.to_s] if value && !value.to_s.empty?
        end
      end

      parts << [40, memory_block(memories, budget)] if memories.any?
      parts << [10, extra.to_s] if extra && !extra.to_s.empty?
      parts << [90, "Current time: #{Time.now.strftime('%Y-%m-%d %H:%M %Z')}."]

      assemble(parts, budget)
    end

    def autonomy_text(level)
      case level
      when :strict
        "STRICT: Never take irreversible actions autonomously. Always create a " \
          "suggestion and wait for human approval."
      when :advisory
        "ADVISORY: You may recommend proactively. High-impact actions still " \
          "require human confirmation."
      else
        "SILENT: Log your reasoning internally. Do not interrupt the user."
      end
    end

    # Memories are truncated by importance, not by array order, so the budget
    # cuts the least valuable ones.
    def memory_block(memories, budget)
      allowance = (budget * 0.4).to_i
      lines = memories
              .sort_by { |m| -(m.respond_to?(:importance) ? m.importance.to_f : 0.5) }
              .map.with_index(1) { |m, i| "[#{i}] (#{m.memory_type}, conf #{m.confidence}) #{m.content}" }

      kept  = []
      spent = 0
      lines.each do |line|
        cost = estimate_tokens(line)
        break if spent + cost > allowance

        kept << line
        spent += cost
      end
      kept << "… #{lines.size - kept.size} more memories omitted (context budget)" if kept.size < lines.size
      "## Relevant Past Knowledge\n#{kept.join("\n")}"
    end

    def assemble(parts, budget)
      ordered = parts.reject { |(_, text)| text.nil? || text.to_s.strip.empty? }
                     .sort_by { |(priority, _)| -priority }
      out   = []
      spent = 0
      ordered.each do |(_, text)|
        cost = estimate_tokens(text)
        next if spent + cost > budget

        out << text.to_s.strip
        spent += cost
      end
      out.join("\n\n")
    end

    def estimate_tokens(text) = (text.to_s.length / 4.0).ceil

    def safely
      yield
    rescue StandardError => e
      Agentkit.logger&.warn("[AgentKit::ContextEngineer] provider failed: #{e.message}")
      nil
    end
  end

  # Base class for every agent.
  #
  # The v0.1 surface (`chat`, `memorize!`, `recall!`, `suggest!`, `build_context`,
  # `domain_context`, `agent_log`) is preserved so existing domain agents keep
  # working; everything underneath is new.
  class Agent
    class << self
      # Class-level invocation used by flows and triggers.
      def call(input = nil, context: nil)
        instance = new(context: context)
        instance.method(:call).arity.zero? ? instance.call : instance.call(input)
      end

      # Declarative per-agent memory policy — replaces `totallook`'s override of
      # `memorize!` to gate on a feature flag.
      #
      #   memory_policy level: :log, embedding: :never
      def memory_policy(**overrides)
        @memory_policy = overrides
      end

      def memory_policy_overrides
        @memory_policy || (superclass.respond_to?(:memory_policy_overrides) ? superclass.memory_policy_overrides : nil)
      end

      # Skills this agent composes into its system prompt and tool set.
      def uses_skills(*names)
        @skills = names.flatten
      end

      def skills = @skills || (superclass.respond_to?(:skills) ? superclass.skills : []) || []

      def prompt_id(value = nil)
        return @prompt_id || (superclass.respond_to?(:prompt_id) ? superclass.prompt_id : nil) if value.nil?

        @prompt_id = value
      end
    end

    attr_reader :agent_context

    def initialize(context: nil, user: nil, account: nil)
      @agent_context =
        if context
          context
        elsif user || account
          Context.new(user: user, account: account)
        else
          Context.resolve
        end
    end

    # v0.1 compatibility accessors.
    def current_user    = agent_context.user
    def current_account = agent_context.account

    def call(*)
      raise NotImplementedError, "#{self.class.name}#call must be implemented"
    end

    # ─── LLM ─────────────────────────────────────────────────────────────────

    # Returns the text (or the parsed hash when a schema is given), matching
    # v0.1's contract. Use #complete for the full response object.
    def chat(prompt, model: nil, system: nil, schema: nil, tools: nil, temperature: nil,
             max_tokens: nil, stream: nil)
      response = complete(prompt, model: model, system: system, schema: schema, tools: tools,
                          temperature: temperature, max_tokens: max_tokens, stream: stream)
      schema ? response.parsed : response.content
    end

    def complete(prompt, model: nil, system: nil, schema: nil, tools: nil, temperature: nil,
                 max_tokens: nil, stream: nil)
      prompt_text, version = resolve_prompt(system)
      response = LLM.complete(
        prompt,
        model: model || default_model, system: prompt_text || build_context,
        schema: schema || default_schema, tools: tools || default_tools,
        temperature: temperature, max_tokens: max_tokens, stream: stream,
        agent: self.class.name, prompt_id: self.class.prompt_id, prompt_version: version
      )
      @last_usage = response.usage
      Memory.mark_used(@last_memories, response.content, agent: self.class.name) if @last_memories&.any?
      response
    end

    def last_usage = @last_usage

    # ─── Memory ──────────────────────────────────────────────────────────────

    def memorize!(content, tags: [], type: "observation", confidence: 0.7, importance: nil,
                  role: nil, derived_from: nil, embed: nil, ttl: nil, ontological_type: "real")
      Memory.store(
        content, source_agent: self.class.name, tags: tags, type: type,
        confidence: confidence, importance: importance, role: role,
        derived_from: derived_from, embed: embed, ttl: ttl,
        ontological_type: ontological_type, context: effective_context
      )
    end
    alias remember! memorize!

    def recall!(query, k: nil, threshold: nil, types: nil, tags: nil, mode: nil,
                include: nil, embed_query: true)
      @last_memories = Memory.recall(
        query, k: k, threshold: threshold, types: types, tags: tags, mode: mode,
        include: include, embed_query: embed_query, agent: self.class.name,
        context: effective_context
      )
    end

    # Explicit opt-in to imagined scenarios. Never returned by `recall!`.
    def recall_imagined!(query, k: 3, min_innovation: 0.5)
      Memory.recall(query, k: k, include: :imagined, types: %w[scenario],
                    agent: self.class.name, context: effective_context)
           .select { |m| m.metadata["innovation_score"].to_f >= min_innovation }
    end

    # ─── HITL ────────────────────────────────────────────────────────────────

    def suggest!(type:, title:, description: nil, priority: "medium", payload: {},
                 suggestable: nil, idempotency_key: nil)
      HITL.suggest!(
        type: type, title: title, description: description, priority: priority,
        payload: payload, suggestable: suggestable, source_agent: self.class.name,
        idempotency_key: idempotency_key, prompt_id: self.class.prompt_id,
        prompt_version: @prompt_version, model: @last_usage&.model,
        context: effective_context
      )
    end

    # ─── Context ─────────────────────────────────────────────────────────────

    def build_context(query: nil, extra: nil, budget: nil)
      memories = query ? recall!(query) : []
      ContextEngineer.build(agent: self, query: query, memories: memories,
                            skills: self.class.skills, extra: extra,
                            budget: budget || ContextEngineer::DEFAULT_BUDGET)
    end

    # Override in the domain's ApplicationAgent.
    def domain_context = ""

    # ─── Logging ─────────────────────────────────────────────────────────────

    # Kept for compatibility. It no longer writes a row per call: it emits a
    # telemetry event, buffered and sampled. `tres` disabled v0.1's version
    # precisely because it did a synchronous INSERT on every chat.
    # Two destinations, on purpose:
    #   Audit     — the full payload, immutable, never sampled (v0.1 parity).
    #   Telemetry — the numeric measures, buffered and sampled, for the factory.
    #
    # An earlier v2 draft sent this to Telemetry only, which silently discarded
    # every non-numeric field and let the record expire. That was a regression
    # against v0.1's `agentkit_agent_logs`.
    def agent_log(event:, payload: {}, prompt: nil, status: nil, subject: nil)
      Audit.record(
        event_type: event, agent_name: self.class.name,
        status: status || event.to_s, payload: payload, prompt: prompt,
        usage: @last_usage, subject: subject, context: agent_context
      )
      Telemetry.emit("agent.#{event}",
                     dims: { agent: self.class.name, event: event.to_s },
                     measures: payload.select { |_, v| v.is_a?(Numeric) })
      nil
    end

    private

    def effective_context
      overrides = self.class.memory_policy_overrides
      return agent_context if overrides.nil?

      @effective_context ||= begin
        memory_overrides = overrides.dup
        memory_overrides[:embedding] = { policy: memory_overrides[:embedding] } if memory_overrides[:embedding].is_a?(Symbol)
        Context.new(
          user: agent_context.user, account: agent_context.account,
          tenant_key: agent_context.tenant_key, run_id: agent_context.run_id,
          trace_id: agent_context.trace_id, budget: agent_context.budget,
          config: agent_context.config.with(memory: memory_overrides),
          metadata: agent_context.metadata
        )
      end
    end

    def resolve_prompt(system)
      return [system, nil] if system
      return [nil, nil] unless self.class.prompt_id && Prompt.defined?(self.class.prompt_id)

      text, version = Prompt.render(self.class.prompt_id, agent_context)
      @prompt_version = version
      [text, version]
    end

    def default_model  = nil
    def default_schema = nil

    def default_tools
      names = self.class.skills
      return nil if names.empty?

      tools = SkillRegistry.tools_for(*names)
      tools.empty? ? nil : tools
    end
  end

  # v0.1 name kept so domain `class ApplicationAgent < Agentkit::ApplicationAgent`
  # keeps compiling.
  ApplicationAgent = Agent
end
