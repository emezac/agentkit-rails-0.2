# frozen_string_literal: true

module Agentkit
  # Per-run snapshot: descriptors are cheap; procedures/providers load on demand.
  class SkillCatalog
    attr_reader :entries

    def initialize(skills:, context:, settings:, authorize: nil)
      @context, @settings = context, settings
      @authorize = authorize
      @entries, @loaded, @activated = {}, {}, []
      raise ConfigurationError, "too many loop skills" if skills.size > settings.max_skills
      skills.each do |skill|
        skill = SkillRegistry.load_skill(skill) if skill.is_a?(Symbol) || skill.is_a?(String)
        raise ConfigurationError, "loop skills must be registered Skill objects" unless skill.is_a?(Skill)
        name = skill.name.to_s
        unless name.match?(/\A[a-zA-Z0-9_-]{1,64}\z/) && !entries.key?(name)
          raise ConfigurationError, "duplicate or invalid loop skill name"
        end
        prompt = skill.prompt
        @entries[name] = {
          skill: skill, prompt: prompt.is_a?(String) ? prompt.dup.freeze : prompt,
          providers: skill.context_providers.values.map { |provider| provider.dup.freeze }.freeze,
          tools: skill.tools.values.dup.freeze,
          descriptor: Harness.deep_freeze(
            "name" => name, "description" => skill.description.to_s.dup,
            "trigger" => skill.trigger.to_s.dup, "version" => skill.version.to_s.dup,
            "owner" => skill.owner.to_s.dup
          )
        }.freeze
      end
      @entries.freeze
    end

    def descriptors = entries.values.select { |entry| permitted?(entry) }.map { |entry| entry.fetch(:descriptor) }
    def tools = entries.values.flat_map { |entry| entry.fetch(:tools) }
    def loaded_names = @activated.dup.freeze
    def mark_loaded!(name)
      @activated |= [name.to_s]
    end
    def permits_tool?(tool)
      entries.values.any? { |entry| entry.fetch(:tools).include?(tool) && permitted?(entry) }
    end

    def load(name, permitted:)
      key = name.to_s
      entry = entries.fetch(key) { raise ToolExecutionDenied, "skill is unavailable" }
      raise ToolExecutionDenied, "skill is unavailable" unless permitted?(entry)
      permitted_names = entry.fetch(:tools).select { |tool| permitted.call(tool) }.map { |tool| tool.name.to_s }
      if (cached = @loaded[key])
        return cached.merge("tool_names" => permitted_names)
      end
      prompt = entry.fetch(:prompt)
      instructions = prompt.respond_to?(:call) ? prompt.call(@context).to_s : prompt.to_s
      sources = entry.fetch(:providers).map do |provider|
        content = provider.call(@context).to_s
        { "name" => provider.name.to_s, "kind" => "untrusted_context",
          "content" => Harness.truncate(content, @context.config.harness.max_context_source_bytes),
          "digest" => Harness.digest(content) }
      end
      payload = entry.fetch(:descriptor).merge(
        "kind" => "skill_instructions", "instructions" => instructions,
        "context_sources" => sources, "tool_names" => permitted_names
      )
      if JSON.generate(payload).bytesize > @settings.max_skill_bytes
        raise AgentLoopLimitExceeded, "skill exceeds loop byte limit"
      end
      @loaded[key] = Harness.deep_freeze(payload)
    end

    private

    def permitted?(entry)
      !@authorize || @authorize.call(entry.fetch(:skill), @context) == true
    rescue StandardError
      false
    end
  end
end
