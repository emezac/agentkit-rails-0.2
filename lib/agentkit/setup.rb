# frozen_string_literal: true

module Agentkit
  # The operating profile: the structured, versioned answer to "according to
  # your setup".
  #
  # A proposal that says "de acuerdo a tu setup te propongo X" is only honest if
  # the setup is data the engine can read and cite — not prose pasted into a
  # system prompt. Versioning matters too: a proposal records which setup
  # version produced it, so the factory can attribute a change in quality to a
  # change in configuration.
  #
  #   Agentkit::Setup.define do
  #     field :objective, type: :enum, values: %i[growth retention efficiency], required: true
  #     field :icp, type: :struct do
  #       field :sectors, type: :array
  #       field :company_size, type: :range
  #     end
  #     field :autonomy, type: :enum, values: %i[propose_only propose_and_do full],
  #                      default: :propose_only
  #   end
  #
  #   setup = Agentkit::Setup.build(objective: :growth, icp: { sectors: %w[saas] })
  class Setup
    Field = Struct.new(:name, :type, :values, :required, :default, :schema, keyword_init: true)

    class Schema
      attr_reader :fields

      def initialize
        @fields = {}
      end

      def field(name, type: :string, values: nil, required: false, default: nil, &block)
        @fields[name.to_sym] = Field.new(
          name: name.to_sym, type: type, values: values, required: required,
          default: default, schema: block ? Schema.new.tap { |s| s.instance_eval(&block) } : nil
        )
      end

      def validate(values)
        problems = []
        @fields.each_value do |f|
          value = values[f.name]
          if value.nil?
            problems << "missing required setup field `#{f.name}`" if f.required && f.default.nil?
            next
          end
          if f.type == :enum && f.values && !Array(f.values).map(&:to_s).include?(value.to_s)
            problems << "`#{f.name}` must be one of #{Array(f.values).join(', ')}"
          end
          problems.concat(f.schema.validate(symbolize(value)).map { |m| "#{f.name}.#{m}" }) if f.schema && value.is_a?(Hash)
        end
        problems
      end

      def defaults
        @fields.each_value.with_object({}) { |f, acc| acc[f.name] = f.default unless f.default.nil? }
      end

      def symbolize(hash) = hash.is_a?(Hash) ? hash.transform_keys(&:to_sym) : hash
    end

    class << self
      def schema = @schema ||= Schema.new

      def define(&block)
        schema.instance_eval(&block)
        schema
      end

      # Accepts either a hash or keyword arguments.
      def build(values = {}, version: nil, **rest)
        new(values.merge(rest), version: version)
      end

      attr_accessor :current

      def reset!
        @schema  = Schema.new
        @current = nil
        self
      end
    end

    attr_reader :values, :version, :updated_at

    def initialize(values = {}, version: nil)
      @values     = self.class.schema.defaults.merge(symbolize(values))
      @version    = version || 1
      @updated_at = Time.now
    end

    def [](key)  = @values[key.to_sym]
    def key?(k)  = @values.key?(k.to_sym)

    def objective = self[:objective]
    def autonomy  = self[:autonomy] || :propose_only
    def icp       = self[:icp] || {}
    def constraints = self[:constraints] || {}

    def connected  = Array(self[:connected]).map(&:to_sym)
    def connected?(name) = connected.include?(name.to_sym)

    def propose_only? = autonomy.to_sym == :propose_only
    def full_autonomy? = autonomy.to_sym == :full

    def forbidden?(action)
      Array(constraints[:forbidden_actions] || constraints["forbidden_actions"])
        .map(&:to_s).include?(action.to_s)
    end

    # Generic ICP match used as the default `fit` for capabilities that do not
    # define their own. Returns 0..1 with the reasons that produced it, so a
    # proposal can cite *why* it fits.
    def icp_match(candidate)
      return [0.5, []] if icp.empty? || candidate.nil?

      reasons = []
      score   = 0.0
      checks  = 0

      if (sectors = icp[:sectors] || icp["sectors"]) && candidate.respond_to?(:sector)
        checks += 1
        if Array(sectors).map(&:to_s).include?(candidate.sector.to_s)
          score += 1
          reasons << "sector #{candidate.sector} está en tu ICP"
        end
      end
      if (geos = icp[:geos] || icp["geos"]) && candidate.respond_to?(:geo)
        checks += 1
        if Array(geos).map(&:to_s).include?(candidate.geo.to_s)
          score += 1
          reasons << "geografía #{candidate.geo} está en tu ICP"
        end
      end
      if (size = icp[:company_size] || icp["company_size"]) && candidate.respond_to?(:size)
        checks += 1
        if size.respond_to?(:cover?) && size.cover?(candidate.size)
          score += 1
          reasons << "tamaño #{candidate.size} entra en tu rango objetivo"
        end
      end

      checks.zero? ? [0.5, []] : [(score / checks).round(3), reasons]
    end

    # Setup evolves from evidence: a repeated `wrong_target` rejection in a
    # sector is a reason to ask whether that sector belongs in the ICP.
    def suggest_adjustments(ledger, since: nil)
      profile = ledger.rejection_profile(since: since)
      out = []
      if profile["wrong_target"].to_f > 0.4
        out << { field: "icp.sectors", reason: "wrong_target domina los rechazos (#{(profile['wrong_target'] * 100).round}%)",
                 action: :review }
      end
      if profile["too_risky"].to_f > 0.3
        out << { field: "autonomy", reason: "too_risky recurrente: considerá bajar la autonomía", action: :lower_autonomy }
      end
      if profile["wrong_tone"].to_f > 0.3
        out << { field: "constraints.tone", reason: "wrong_tone recurrente", action: :review }
      end
      out
    end

    def with(changes)
      self.class.new(@values.merge(symbolize(changes)), version: @version + 1)
    end

    def validate = self.class.schema.validate(@values)
    def valid?   = validate.empty?

    def to_h = @values.merge(_version: @version)

    private

    def symbolize(hash) = hash.is_a?(Hash) ? hash.transform_keys(&:to_sym) : {}
  end
end
