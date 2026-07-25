# frozen_string_literal: true

module Agentkit
  # Minimal settings object with a declarative DSL, nested groups, validation
  # and cheap copy-on-override.
  #
  # v0.1 used a flat Configuration with plain attr_accessors, which forced
  # projects to reopen the class to add their own keys (dos/maas added
  # :advisory_auto_apply_delay by monkeypatching). Here, `[]`/`[]=` accept
  # unknown keys into an `extra` bag, so a domain never has to reopen anything.
  #
  #   class MemorySettings < Agentkit::Settings
  #     setting :level, default: :hybrid, in: %i[off log keyword hybrid semantic full]
  #     group   :embedding, EmbeddingSettings
  #   end
  #
  #   cfg = MemorySettings.new
  #   cfg.level                       # => :hybrid
  #   cfg.embedding.policy            # => :on_promotion
  #   tenant_cfg = cfg.with(level: :keyword)   # copy, original untouched
  class Settings
    class << self
      def settings_schema
        @settings_schema ||= superclass.respond_to?(:settings_schema) ? superclass.settings_schema.dup : {}
      end

      def groups_schema
        @groups_schema ||= superclass.respond_to?(:groups_schema) ? superclass.groups_schema.dup : {}
      end

      # Declare a scalar setting.
      #
      # @param name    [Symbol]
      # @param default [Object, Proc] static default, or a callable evaluated lazily
      # @param in      [Array, nil]   allowed values (validated on assignment)
      # @param type    [Class, Array<Class>, nil] allowed ruby types
      def setting(name, default: nil, **opts)
        allowed = opts[:in]
        type    = opts[:type]
        settings_schema[name.to_sym] = { default: default, in: allowed, type: type }

        # Lazy defaults are memoized on first read. Without this, a collection
        # default (`profiles`, `features`, `sampling`) would hand out a fresh
        # object every call and any mutation would silently vanish.
        define_method(name) do
          key = name.to_sym
          @values.fetch(key) { @values[key] = self.class.default_for(key) }
        end
        define_method(:"#{name}=") { |value| write_setting(name.to_sym, value) }
        define_method(:"#{name}?") { !!public_send(name) } unless name.to_s.end_with?("?")
      end

      # Declare a nested settings group.
      def group(name, klass)
        groups_schema[name.to_sym] = klass
        define_method(name) { @groups[name.to_sym] ||= klass.new }
        define_method(:"#{name}=") do |value|
          @groups[name.to_sym] = value.is_a?(Settings) ? value : klass.new.merge!(value)
        end
      end

      def default_for(name)
        spec = settings_schema.fetch(name) { raise ConfigurationError, "Unknown setting #{name}" }
        d = spec[:default]
        d.respond_to?(:call) && !d.is_a?(Module) ? d.call : d
      end
    end

    attr_reader :extra

    def initialize(values = {})
      @values = {}
      @groups = {}
      @extra  = {}
      merge!(values) if values && !values.empty?
    end

    # Deep merge a plain hash into this settings object.
    def merge!(hash)
      (hash || {}).each do |key, value|
        key = key.to_sym
        if self.class.groups_schema.key?(key)
          public_send(key).merge!(value.is_a?(Settings) ? value.to_h : value)
        elsif self.class.settings_schema.key?(key)
          write_setting(key, value)
        else
          # Unknown key: keep it instead of raising. Domains extend freely.
          @extra[key] = value
        end
      end
      self
    end

    # Copy with overrides — the mechanism behind per-tenant / per-agent / per-call
    # configuration. The receiver is never mutated.
    def with(overrides = {})
      copy = self.class.new
      copy.instance_variable_set(:@values, @values.dup)
      copy.instance_variable_set(:@extra, @extra.dup)
      copy.instance_variable_set(:@groups, @groups.transform_values { |g| g.with })
      copy.merge!(overrides)
      copy
    end

    def [](key)
      key = key.to_sym
      return public_send(key) if respond_to?(key)

      @extra[key]
    end

    def []=(key, value)
      key = key.to_sym
      return public_send(:"#{key}=", value) if respond_to?(:"#{key}=")

      @extra[key] = value
    end

    def to_h
      base = self.class.settings_schema.keys.to_h { |k| [k, public_send(k)] }
      groups = self.class.groups_schema.keys.to_h { |k| [k, public_send(k).to_h] }
      base.merge(groups).merge(@extra)
    end

    # Collects validation problems instead of raising on the first one, so
    # `agentkit:doctor` can report everything at once.
    def validate
      problems = []
      self.class.settings_schema.each_key do |name|
        value = public_send(name)
        spec  = self.class.settings_schema[name]
        problems << "#{self.class.name}##{name}: #{value.inspect} not in #{spec[:in].inspect}" if invalid_inclusion?(spec, value)
        problems << "#{self.class.name}##{name}: #{value.class} is not #{spec[:type]}" if invalid_type?(spec, value)
      end
      self.class.groups_schema.each_key { |g| problems.concat(public_send(g).validate) }
      problems
    end

    def respond_to_missing?(name, include_private = false)
      @extra.key?(name.to_s.delete_suffix("=").to_sym) || super
    end

    def method_missing(name, *args)
      key = name.to_s.delete_suffix("=").to_sym
      return @extra[key] = args.first if name.to_s.end_with?("=")
      return @extra[key] if @extra.key?(key)

      super
    end

    private

    def write_setting(name, value)
      spec = self.class.settings_schema[name]
      raise ConfigurationError, "#{self.class.name}##{name} must be one of #{spec[:in].inspect}, got #{value.inspect}" if invalid_inclusion?(spec, value)

      @values[name] = value
    end

    def invalid_inclusion?(spec, value)
      return false if spec.nil? || spec[:in].nil? || value.nil?

      !Array(spec[:in]).include?(value)
    end

    def invalid_type?(spec, value)
      return false if spec.nil? || spec[:type].nil? || value.nil?

      Array(spec[:type]).none? { |t| value.is_a?(t) }
    end
  end
end
