# frozen_string_literal: true

module Agentkit
  # Resolves a routing profile to a concrete provider + model + parameters.
  #
  # v0.1's router was a `case` over five config strings: it knew nothing about
  # providers, temperature, timeouts or fallbacks, which is why every Qwen
  # project had to configure ruby_llm by hand in an initializer.
  module ModelRouter
    PROFILES = %i[fast default complex code vision].freeze

    class << self
      # @param profile_or_model [Symbol, String, ModelProfile]
      # @return [ModelProfile]
      def profile_for(profile_or_model)
        case profile_or_model
        when ModelProfile then profile_or_model
        when String       then ad_hoc(profile_or_model)
        when nil          then profiles.fetch(:default)
        else
          profiles[profile_or_model.to_sym] ||
            raise(ConfigurationError, "Unknown model profile #{profile_or_model.inspect}. " \
                                      "Available: #{profiles.keys.join(', ')}")
        end
      end

      # Back-compat with v0.1 (`ModelRouter.resolve(:complex) # => "claude-opus-4-6"`).
      def resolve(profile_or_model)
        profile_for(profile_or_model).model
      end

      def fallback_for(profile_or_model)
        return nil if profile_or_model.is_a?(String)

        profile_for(profile_or_model).fallback
      end

      def profiles
        Agentkit.config.llm.profiles
      end

      # Register or replace a profile at runtime.
      #
      #   ModelRouter.register(:cheap, model: "qwen-flash", provider: :openai_compatible)
      def register(name, **attrs)
        profiles[name.to_sym] = ModelProfile.new(**attrs)
      end

      def all_models
        profiles.values.map(&:model).compact.uniq
      end

      # Every model referenced must have a price, otherwise cost tracking lies
      # by omission. Surfaced by `agentkit:doctor`.
      def unpriced_models
        all_models.reject { |m| LLM::Pricing.known?(m) }
      end

      private

      def ad_hoc(model_string)
        template = profiles[:default]
        ModelProfile.new(
          model: model_string,
          provider: template&.provider || Agentkit.config.llm.adapter,
          timeout: template&.timeout
        )
      end
    end
  end
end
