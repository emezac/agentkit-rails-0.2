# frozen_string_literal: true

module Agentkit
  module Memory
    # Decides *whether*, *when* and *how* a memory gets a vector.
    #
    # This is the whole point of v2's memory layer. In v0.1, `MemoryEngine.store`
    # ended with an unconditional `EmbeddingJob.perform_later(memory.id)` — one
    # API call per memory, no batching, no dedupe, no budget — and the lifecycle
    # then archived those same rows during the nightly dreaming cycle. You paid
    # for vectors that were thrown away hours later.
    #
    # Storing and vectorising are two decisions here, and the second one is
    # configurable at four levels: global → tenant → agent → call.
    module Policy
      # Decision values:
      #   :now        embed immediately (blocking or job, caller decides)
      #   :batch      queue for the next batch flush
      #   :defer      wait for promotion / first recall need
      #   :never      no vector, ever
      DECISIONS = %i[now batch defer never].freeze

      module_function

      # @param memory   [Record]
      # @param config   [MemorySettings]
      # @param override [Symbol, Boolean, nil] per-call `embed:` argument
      def decide(memory, config, override: nil)
        return :never unless config.vectors?
        return normalize_override(override) unless override.nil?

        case config.embedding.policy
        when :never      then :never
        when :immediate  then :now
        when :batched    then :batch
        when :manual     then :never
        when :lazy       then :defer
        when :sampled    then sampled(config)
        when :on_promotion then promoted?(memory, config) ? :batch : :defer
        else :batch
        end
      end

      # A memory is "promoted" when it is the kind of thing people actually
      # search for: a consolidated insight, something recalled repeatedly, or
      # something the agent marked as important.
      #
      # Under :on_promotion, 20 raw observations that consolidate into 3 insights
      # cost 3 embeddings instead of 20.
      def promoted?(memory, config)
        rules = config.promotion
        return true if Array(rules.types).map(&:to_s).include?(memory.memory_type.to_s)
        return true if memory.importance.to_f >= rules.min_importance.to_f
        return true if memory.recall_count.to_i >= rules.min_recalls.to_i
        return true if memory.promoted_at

        false
      end

      def sampled(config)
        Kernel.rand < config.embedding.sample_rate.to_f ? :batch : :never
      end

      def normalize_override(override)
        case override
        when true, :now, :immediate then :now
        when false, :never          then :never
        when :batch, :batched       then :batch
        when :defer, :lazy, :on_promotion then :defer
        else raise ArgumentError, "Unknown embed: #{override.inspect}"
        end
      end

      # Which retrieval mode can this configuration actually serve?
      # Degrading (rather than raising) is what keeps a budget overrun from
      # taking the product down.
      def retrieval_mode(config, requested: nil)
        available = case config.level
                    when :off, :log  then :none
                    when :keyword    then :keyword
                    when :hybrid     then :hybrid
                    when :semantic, :full then :semantic
                    end
        return available if requested.nil?

        rank = { none: 0, keyword: 1, hybrid: 2, semantic: 3 }
        rank[requested] <= rank[available] ? requested : available
      end

      # Model/dimensions for a memory type, honouring the `tiers` table.
      # An observation does not need 1536 dimensions.
      def embedding_spec(memory, config)
        tier = config.embedding.tiers[memory.memory_type.to_s.to_sym] ||
               config.embedding.tiers[memory.memory_type.to_s]
        {
          model:      tier&.dig(:model) || tier&.dig("model") || config.embedding.model,
          dimensions: tier&.dig(:dimensions) || tier&.dig("dimensions") || config.embedding.dimensions
        }
      end
    end
  end
end
