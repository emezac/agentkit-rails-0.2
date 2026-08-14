# frozen_string_literal: true

module Agentkit
  # Every agent and every flow step returns one of these. v0.1 agents returned
  # whatever `chat` returned and raised on failure, which made partial results
  # impossible (`join on: :all_settled` needs a failed branch to be a value, not
  # an exception) and lost the side effects an agent produced.
  #
  #   Result.ok(text, memories: [m], suggestions: [s], usage: usage)
  #   Result.err(error, retryable: true)
  #
  # Side-effect accessors are always arrays, so callers never nil-check.
  class Result
    attr_reader :value, :error, :memories, :suggestions, :artifacts, :usage, :metadata

    class << self
      def ok(value = nil, memories: [], suggestions: [], artifacts: [], usage: nil, **metadata)
        new(ok: true, value: value, memories: memories, suggestions: suggestions,
            artifacts: artifacts, usage: usage, metadata: metadata)
      end

      def err(error, retryable: false, value: nil, **metadata)
        new(ok: false, error: error, retryable: retryable, value: value,
            metadata: metadata)
      end

      # Wrap an arbitrary return value. Steps written as plain blocks can return
      # anything and still take part in the pipeline.
      def wrap(object)
        return object if object.is_a?(Result)

        ok(object)
      end

      # Run a block, converting exceptions into a failed Result.
      # Uses wrap() rather than ok() so that agents returning Result.ok(...)
      # are not double-wrapped into Result.ok(Result.ok(...)).
      def capture(retryable_on: [TransientError])
        wrap(yield)
      rescue StandardError => e
        err(e, retryable: retryable_on.any? { |k| e.is_a?(k) })
      end
    end

    def initialize(ok:, value: nil, error: nil, retryable: false, memories: [],
                   suggestions: [], artifacts: [], usage: nil, metadata: {})
      @ok          = ok
      @value       = value
      @error       = error
      @retryable   = retryable
      @memories    = Array(memories)
      @suggestions = Array(suggestions)
      @artifacts   = Array(artifacts)
      @usage       = usage
      @metadata    = metadata || {}
      freeze
    end

    def ok?        = @ok
    def err?       = !@ok
    def retryable? = @retryable

    # Set when a Result comes out of a Flow, so callers can inspect the run
    # without the executor having to mutate a frozen object.
    def run = @metadata[:run]

    # Copy with extra metadata (Result is frozen by design).
    def with_metadata(extra)
      Result.new(ok: @ok, value: @value, error: @error, retryable: @retryable,
                 memories: @memories, suggestions: @suggestions, artifacts: @artifacts,
                 usage: @usage, metadata: @metadata.merge(extra))
    end

    # Convenience accessors for the single-item case, which is the common one.
    def memory     = @memories.first
    def suggestion = @suggestions.first
    def artifact   = @artifacts.first

    # Hash delegation convenience when value is a Hash
    def [](key)
      return nil unless value.is_a?(Hash)

      value[key] || value[key.to_sym] rescue nil
    end

    # Raise the wrapped error. Used at the boundary where a caller wants
    # exception semantics (controllers, rake tasks).
    def value!
      raise(error.is_a?(Exception) ? error : Error.new(error.to_s)) if err?

      value
    end

    def unwrap_or(default) = ok? ? value : default

    # Chain. The block is skipped on failure, so a pipeline short-circuits.
    def then
      return self if err?

      Result.wrap(yield(value))
    end

    def merge(other)
      Result.new(
        ok:          ok? && other.ok?,
        value:       other.ok? ? other.value : value,
        error:       error || other.error,
        retryable:   retryable? || other.retryable?,
        memories:    memories + other.memories,
        suggestions: suggestions + other.suggestions,
        artifacts:   artifacts + other.artifacts,
        usage:       Usage.sum([usage, other.usage].compact),
        metadata:    metadata.merge(other.metadata)
      )
    end

    def to_h
      {
        ok: ok?, value: value, error: error&.to_s, retryable: retryable?,
        memories: memories.size, suggestions: suggestions.size,
        artifacts: artifacts.size, usage: usage&.to_h, metadata: metadata
      }
    end

    def inspect
      ok? ? "#<Agentkit::Result ok value=#{value.inspect.slice(0, 80)}>" : "#<Agentkit::Result err #{error}>"
    end
  end

  # Token / cost accounting for a single call or an aggregate.
  # v0.1 declared a `cost_usd` column and never wrote it; this is what fills it.
  class Usage
    attr_reader :input_tokens, :output_tokens, :cost_usd, :duration_ms, :calls,
                :cached, :model

    def initialize(input_tokens: 0, output_tokens: 0, cost_usd: 0.0, duration_ms: 0,
                   calls: 1, cached: false, model: nil)
      @input_tokens  = input_tokens.to_i
      @output_tokens = output_tokens.to_i
      @cost_usd      = cost_usd.to_f
      @duration_ms   = duration_ms.to_i
      @calls         = calls.to_i
      @cached        = cached
      @model         = model
      freeze
    end

    def total_tokens = input_tokens + output_tokens
    def cached?      = !!@cached

    def +(other)
      return self if other.nil?

      Usage.new(
        input_tokens:  input_tokens + other.input_tokens,
        output_tokens: output_tokens + other.output_tokens,
        cost_usd:      cost_usd + other.cost_usd,
        duration_ms:   duration_ms + other.duration_ms,
        calls:         calls + other.calls,
        cached:        cached? && other.cached?,
        model:         model == other.model ? model : nil
      )
    end

    def self.sum(usages)
      usages.compact.reduce(:+)
    end

    def self.zero = new(input_tokens: 0, output_tokens: 0, calls: 0)

    def to_h
      { input_tokens: input_tokens, output_tokens: output_tokens,
        total_tokens: total_tokens, cost_usd: cost_usd.round(6),
        duration_ms: duration_ms, calls: calls, cached: cached?, model: model }.compact
    end
  end
end
