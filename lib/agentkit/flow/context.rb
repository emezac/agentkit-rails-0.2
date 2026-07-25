# frozen_string_literal: true

module Agentkit
  class Flow
    # What a step body sees. Read-only over already-executed steps: no local
    # variable survives between steps, everything travels through `output`, and
    # that is exactly why a run can be resumed from the database.
    class FlowContext
      attr_reader :input, :run, :context, :state

      def initialize(input:, run:, context:, state: {})
        @input   = symbolize(input)
        @run     = run
        @context = context
        @state   = state
        @results = {}
        @order   = []
      end

      # ctx[:step_name] → Result (or StepResults for parallel/map)
      def [](name)
        @results[name.to_sym]
      end

      def set(name, value)
        name = name.to_sym
        @order << name unless @results.key?(name)
        @results[name] = value
      end

      def key?(name) = @results.key?(name.to_sym)
      def last       = @order.empty? ? nil : @results[@order.last]
      def results    = @results.dup

      # Total usage accumulated so far — lets a step decide to downgrade the
      # model when a run is getting expensive.
      def usage
        Usage.sum(@results.values.filter_map { |r| r.respond_to?(:usage) ? r.usage : nil })
      end

      def to_h
        { input: @input, results: @results.transform_values { |r| r.respond_to?(:to_h) ? r.to_h : r } }
      end

      private

      def symbolize(hash)
        return hash unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end
    end

    # Collection of branch results from parallel/map. Behaves like a Result for
    # the common case while keeping every branch addressable.
    class StepResults
      include Enumerable

      attr_reader :results, :keys

      def initialize(pairs)
        @keys    = pairs.map(&:first)
        @results = pairs.map(&:last)
      end

      def each(&block) = @results.each(&block)

      def ok?      = @results.all?(&:ok?)
      def err?     = !ok?
      def values   = @results.select(&:ok?).map(&:value)
      def value    = values
      def errors   = @results.select(&:err?).map(&:error)
      def failed   = @results.select(&:err?)
      def size     = @results.size
      def usage    = Usage.sum(@results.filter_map(&:usage))
      def memories = @results.flat_map(&:memories)
      def suggestions = @results.flat_map(&:suggestions)

      # by branch key: ctx[:council][:FinanceBotAgent]
      def [](key)
        idx = @keys.index(key) || @keys.index(key.to_s) || @keys.index(key.to_sym)
        idx ? @results[idx] : nil
      end

      def to_h = { ok: ok?, size: size, values: values, errors: errors.map(&:to_s) }
    end
  end
end
