# frozen_string_literal: true

require_relative "cognition/processors"

module Agentkit
  # Dreaming, Summarizer and Imagination are the same abstraction with a
  # different strategy: a scoped pass over memory that produces new memory,
  # suggestions or artifacts, with a trace.
  #
  # In v0.1 dreaming was a nightly cron job hardcoded to iterate users, which is
  # why all six projects rewrote it. Here cron is *one* trigger among four:
  # cron, HTTP, CLI or a flow step — same code path.
  #
  #   Agentkit::Cognition.run(:dreaming, scope: { account: acc }, dry_run: true)
  #   Agentkit::Cognition.run(:summarizer, source: memories, strategy: :map_reduce)
  module Cognition
    Definition = Struct.new(:name, :processor, :options, keyword_init: true)

    # One trace format for every cognitive process. Lives in Agentkit::Audit so
    # dreaming, summarizing, imagining and councils share the same XAI
    # infrastructure — and, unlike v2's first draft, survive a process restart.
    Trace = Agentkit::Audit::Trace

    class << self
      def registry
        @registry ||= {}
      end

      def define(name, processor: nil, &block)
        options = ProcessorOptions.new
        block&.call(options)
        registry[name.to_sym] = Definition.new(
          name: name.to_sym,
          processor: processor || options.processor || default_processor(name),
          options: options
        )
      end

      def run(name, dry_run: false, trigger: :on_demand, context: nil, **opts)
        definition = registry[name.to_sym] || register_default(name)
        raise ConfigurationError, "Unknown cognition processor #{name}" if definition.nil?

        ctx   = context || Context.resolve
        trace = Trace.new(kind: name.to_s, trigger: trigger.to_s)
        merged = definition.options.to_h.merge(opts)

        definition.processor.new(options: merged, context: ctx, trace: trace)
                  .call(dry_run: dry_run)
      end

      # Persisted traces live in the audit store; this is a convenience reader.
      def traces  = Agentkit::Audit.traces
      def record_trace(trace) = trace

      def reset!
        @registry = {}
        self
      end

      private

      def default_processor(name)
        case name.to_sym
        when :dreaming    then Processors::Dreaming
        when :summarizer  then Processors::Summarizer
        when :imagination then Processors::Imagination
        end
      end

      def register_default(name)
        klass = default_processor(name)
        return nil if klass.nil?

        define(name, processor: klass)
      end
    end

    # Declarative options for a processor definition.
    class ProcessorOptions
      ATTRS = %i[processor trigger cron scope strategy gate output model dry_run
                 threshold min_cluster min_recalls format budget persist cache
                 divergence gates ttl backend source audience].freeze

      attr_accessor(*ATTRS)

      def initialize
        @extra = {}
      end

      def trigger(kind = nil, cron_expr = nil)
        return @trigger if kind.nil?

        @trigger = kind
        @cron    = cron_expr
        self
      end

      def method_missing(name, *args)
        key = name.to_s.delete_suffix("=").to_sym
        return @extra[key] = args.first if name.to_s.end_with?("=")
        return @extra[key] if @extra.key?(key)
        return (@extra[key] = args.first) if args.any?

        nil
      end

      def respond_to_missing?(*) = true

      def to_h
        ATTRS.to_h { |a| [a, instance_variable_get(:"@#{a}")] }.compact.merge(@extra)
      end
    end
  end
end
