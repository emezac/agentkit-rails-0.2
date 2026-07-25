# frozen_string_literal: true

module Agentkit
  # What the application can actually *do*, declared with preconditions, cost,
  # risk and the flow that executes it.
  #
  # This is what v0.1's SkillRegistry should have been. A skill fragment is text;
  # a capability is an executable action the proposal engine can reason about,
  # the HITL layer can gate by risk, and the factory can exclude from canary
  # experiments when it is irreversible (`astra` hardcoded that exclusion for
  # refunds and cancellations).
  #
  #   Agentkit::Capability.register :import_company_contacts do |c|
  #     c.title "Traer contactos de una empresa"
  #     c.flow  ImportContactsFlow
  #     c.inputs company: :string, roles: :array
  #     c.preconditions { |setup, ctx| setup.connected?(:contacts_provider) }
  #     c.fit  ->(setup, candidate) { setup.icp_match(candidate) }
  #     c.cost ->(inputs) { inputs[:roles].to_a.size * 0.02 }
  #     c.risk :reversible
  #     c.cooldown 7 * 86_400
  #   end
  class Capability
    RISKS = %i[reversible costly irreversible].freeze
    MODES = %i[propose auto strict].freeze

    attr_reader :name

    class << self
      def registry = @registry ||= {}

      def register(name, &block)
        capability = new(name)
        block&.call(capability)
        capability.validate!
        registry[name.to_sym] = capability
      end

      def [](name)  = registry[name.to_sym]
      def all       = registry.values
      def available = registry.keys
      def reset!    = @registry = {}

      # Capabilities whose preconditions hold for this setup/context.
      def eligible(setup, context = nil)
        all.select { |c| c.eligible?(setup, context) }
      end

      # Irreversible actions never enter an experiment arm.
      def experimentable = all.reject { |c| c.risk == :irreversible }
    end

    def initialize(name)
      @name        = name.to_sym
      @title       = name.to_s.tr("_", " ")
      @description = nil
      @flow        = nil
      @agent       = nil
      @inputs      = {}
      @precondition = nil
      @fit_fn      = nil
      @cost_fn     = nil
      @risk        = :reversible
      @hitl        = :propose
      @cooldown    = nil
      @tags        = []
    end

    # DSL — each reader doubles as a writer, so the block reads declaratively.
    def title(v = nil)       = v.nil? ? @title : (@title = v)
    def description(v = nil) = v.nil? ? @description : (@description = v)
    def flow(v = nil)        = v.nil? ? @flow : (@flow = v)
    def agent(v = nil)       = v.nil? ? @agent : (@agent = v)
    def inputs(v = nil)      = v.nil? ? @inputs : (@inputs = v)
    def tags(*v)             = v.empty? ? @tags : (@tags = v.flatten)
    def cooldown(v = nil)    = v.nil? ? @cooldown : (@cooldown = v)

    def risk(v = nil)
      return @risk if v.nil?
      raise ConfigurationError, "risk must be one of #{RISKS.inspect}" unless RISKS.include?(v.to_sym)

      @risk = v.to_sym
    end

    def hitl(v = nil)
      return @hitl if v.nil?
      raise ConfigurationError, "hitl must be one of #{MODES.inspect}" unless MODES.include?(v.to_sym)

      @hitl = v.to_sym
    end

    def preconditions(callable = nil, &block) = @precondition = callable || block
    def fit(callable = nil, &block)           = @fit_fn = callable || block
    def cost(callable = nil, &block)          = @cost_fn = callable || block

    # ─── Evaluation ──────────────────────────────────────────────────────────

    def eligible?(setup, context = nil)
      return true if @precondition.nil?

      !!@precondition.call(setup, context || Context.resolve)
    rescue StandardError => e
      Agentkit.logger&.warn("[AgentKit::Capability] #{name} precondition raised: #{e.message}")
      false
    end

    # 0..1 — how well this capability fits the operating profile for a given
    # subject. Learnable: the factory adjusts ranking weights from the ledger.
    def fit_for(setup, subject = nil)
      return 0.5 if @fit_fn.nil?

      value = @fit_fn.arity == 1 ? @fit_fn.call(setup) : @fit_fn.call(setup, subject)
      value.to_f.clamp(0.0, 1.0)
    rescue StandardError
      0.0
    end

    def cost_for(inputs = {})
      return 0.0 if @cost_fn.nil?

      @cost_fn.call(inputs).to_f
    rescue StandardError
      0.0
    end

    def irreversible? = @risk == :irreversible
    def auto?         = @hitl == :auto

    # Execute. Always through a flow or an agent — a capability is never free
    # text, which is what keeps every action on the same HITL and telemetry rail.
    def execute(inputs = {}, context: nil)
      ctx = context || Context.resolve
      Telemetry.emit("capability.execute", dims: { capability: name, risk: @risk })

      return @flow.call(context: ctx, **inputs) if @flow
      return @agent.call(inputs, context: ctx) if @agent

      raise CapabilityError, "Capability #{name} has neither flow nor agent"
    end

    def validate!
      raise ConfigurationError, "Capability #{name} needs a flow or an agent" if @flow.nil? && @agent.nil?

      true
    end

    def to_h
      { name: name, title: @title, description: @description, risk: @risk, hitl: @hitl,
        inputs: @inputs, tags: @tags, cooldown: @cooldown,
        has_fit: !@fit_fn.nil?, has_cost: !@cost_fn.nil? }
    end
  end
end
