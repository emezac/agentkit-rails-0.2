# frozen_string_literal: true

module Agentkit
  # A skill is a composable unit of agent capability: a prompt fragment, real
  # callable tools, lazy context providers, an output schema and a model
  # preference.
  #
  # v0.1 had a SkillRegistry whose `tools` array was decorative — nothing ever
  # read it — and whose autoloader used `require`, breaking Zeitwerk reloading
  # in development. It ended with zero uses across six projects. Here all four
  # pieces are consumed: prompt → ContextEngineer, tools → function calling,
  # context_providers → context budget, schema → structured output.
  #
  #   Agentkit::Skill.define(:finance) do |s|
  #     s.prompt "## Role: financial analyst. Quantify cash-flow impact."
  #     s.model  :complex
  #     s.tool(:balance_for, description: "Current balance for a company") do |company_id:|
  #       Company.find(company_id).balance
  #     end
  #     s.context_provider(:overdue, tokens: 200) { |ctx| "Overdue: #{Invoice.overdue.count}" }
  #   end
  class Skill
    Tool = Struct.new(:name, :description, :params, :callable, keyword_init: true) do
      def call(**kwargs) = callable.call(**kwargs)

      def to_json_schema
        {
          name: name.to_s,
          description: description.to_s,
          parameters: {
            type: "object",
            properties: (params || {}).transform_values { |t| { type: t.to_s } },
            required: (params || {}).keys.map(&:to_s)
          }
        }
      end
    end

    Provider = Struct.new(:name, :tokens, :priority, :callable, keyword_init: true) do
      def call(ctx) = callable.arity.zero? ? callable.call : callable.call(ctx)
    end

    attr_reader :name, :tools, :context_providers, :output_schema, :model_preference

    def self.define(name, &block)
      skill = new(name)
      block&.call(skill)
      SkillRegistry.register(name, skill)
      skill
    end

    def initialize(name)
      @name              = name.to_sym
      @prompt            = nil
      @tools             = {}
      @context_providers = {}
      @output_schema     = nil
      @model_preference  = nil
    end

    def prompt(text = nil, &block)
      return @prompt.respond_to?(:call) ? @prompt : @prompt if text.nil? && block.nil?

      @prompt = block || text
      self
    end

    def tool(tool_name, description: nil, params: {}, &block)
      @tools[tool_name.to_sym] = Tool.new(name: tool_name.to_sym, description: description,
                                          params: params, callable: block)
      self
    end

    def context_provider(provider_name, tokens: 200, priority: 50, &block)
      @context_providers[provider_name.to_sym] =
        Provider.new(name: provider_name.to_sym, tokens: tokens, priority: priority, callable: block)
      self
    end

    def schema(value = nil)
      return @output_schema if value.nil?

      @output_schema = value
      self
    end

    def model(value = nil)
      return @model_preference if value.nil?

      @model_preference = value
      self
    end

    # Rendered prompt fragment for the context builder.
    def system_prompt_fragment(ctx = nil)
      return "" if @prompt.nil?

      @prompt.respond_to?(:call) ? @prompt.call(ctx).to_s : @prompt.to_s
    end

    def tool_names = @tools.keys
  end

  # Instance-backed registry. v0.1 kept a mutable class ivar and reloaded skills
  # with `require`; this one is a plain hash that `reset!` clears, so a Rails
  # `to_prepare` hook can re-register on every code reload.
  module SkillRegistry
    class << self
      def registry = @registry ||= {}

      def register(name, skill)
        registry[name.to_sym] = skill
        skill
      end

      def load_skill(name)
        registry.fetch(name.to_sym) do
          raise ConfigurationError,
                "Unknown skill: #{name}. Available: #{available.join(', ')}"
        end
      end
      alias [] load_skill

      def compose(*names)
        names.flatten.compact.map { |n| load_skill(n) }
      end
      alias compose_skills compose

      def available = registry.keys

      def registered?(name) = registry.key?(name.to_sym)

      # Look up a tool across all skills — used to resolve `tools: [:balance_for]`
      # into a callable at LLM-call time.
      def tool(tool_name)
        registry.each_value do |skill|
          found = skill.tools[tool_name.to_sym]
          return found if found
        end
        nil
      end

      def tools_for(*skill_names)
        compose(*skill_names).flat_map { |s| s.tools.values }
      end

      def reset!
        @registry = {}
        self
      end
    end
  end
end
