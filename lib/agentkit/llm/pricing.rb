# frozen_string_literal: true

module Agentkit
  module LLM
    # USD per 1M tokens. v0.1 declared a `cost_usd` column and never wrote it,
    # so `astra` had to build CreditGuard outside the kernel to know what it was
    # spending. Prices are data, not code: override or extend at boot.
    #
    #   Agentkit::LLM::Pricing.register("qwen3.7-plus", input: 0.4, output: 1.2)
    module Pricing
      DEFAULTS = {
        # Anthropic
        "claude-opus-4-6"            => { input: 15.0,  output: 75.0 },
        "claude-sonnet-4-6"          => { input: 3.0,   output: 15.0 },
        "claude-haiku-4-5-20251001"  => { input: 0.80,  output: 4.0 },
        # OpenAI embeddings (per 1M tokens)
        "text-embedding-3-small"     => { input: 0.02,  output: 0.0 },
        "text-embedding-3-large"     => { input: 0.13,  output: 0.0 }
      }.freeze

      class << self
        def table
          @table ||= DEFAULTS.dup
        end

        def register(model, input:, output: 0.0)
          table[model.to_s] = { input: input.to_f, output: output.to_f }
        end

        def for(model)
          return nil if model.nil?

          table[model.to_s] || fuzzy(model.to_s)
        end

        # Cost of one call. Explicit per-profile prices win over the table, so a
        # project on a negotiated rate does not have to patch the gem.
        def cost(model:, input_tokens:, output_tokens:, price_in: nil, price_out: nil)
          rates = self.for(model) || {}
          pin   = price_in  || rates[:input]
          pout  = price_out || rates[:output]
          return 0.0 if pin.nil? && pout.nil?

          ((input_tokens.to_i * (pin || 0.0)) + (output_tokens.to_i * (pout || 0.0))) / 1_000_000.0
        end

        def known?(model) = !self.for(model).nil?

        def reset! = @table = DEFAULTS.dup

        private

        # Match "anthropic/claude-sonnet-4.6" or "claude-sonnet-4-6-20260101"
        # against the base entries — `astra` uses provider-prefixed ids.
        def fuzzy(model)
          normalized = model.split("/").last.to_s
          table.find { |k, _| normalized.start_with?(k) || k.start_with?(normalized) }&.last
        end
      end
    end
  end
end
