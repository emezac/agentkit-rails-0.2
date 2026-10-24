# frozen_string_literal: true

require "thread"

module Agentkit
  # Request-scoped admission and measured usage shared by nested loops. Child
  # views attribute usage to their own subtree without double charging parents.
  class ExecutionBudget
    def initialize(max_turns: 20, max_tokens: 100_000, max_cost_usd: 1.0, external: nil,
                   state: nil, ancestors: nil)
      if state
        @state = state
        @ancestors = ancestors + [SecureRandom.uuid]
      else
        unless external.nil? || external.respond_to?(:charge)
          raise ConfigurationError, "external budget must implement charge"
        end
        unless max_turns.is_a?(Integer) && max_turns.positive? && max_tokens.is_a?(Integer) && max_tokens.positive?
          raise ConfigurationError, "execution budget counts must be positive integers"
        end
        if max_cost_usd && (!max_cost_usd.is_a?(Numeric) || !max_cost_usd.finite? || max_cost_usd <= 0)
          raise ConfigurationError, "execution budget cost must be positive and finite or nil"
        end
        @state = { mutex: Mutex.new, max_turns: max_turns, max_tokens: max_tokens,
                   max_cost_usd: max_cost_usd, turns: 0, usage: {}, unpriced: [], external: external }
        @ancestors = [SecureRandom.uuid]
      end
      @state[:mutex].synchronize { @state[:usage][@ancestors.last] = Usage.zero }
    end

    def child
      self.class.new(state: @state, ancestors: @ancestors)
    end

    def admit_model!(profile)
      known = priced?(profile)
      @state[:mutex].synchronize do
        unless known
          @state[:unpriced] |= [profile.model.to_s]
          raise ConfigurationError, "a cost-limited loop requires model input/output pricing" if @state[:max_cost_usd]
        end
        check_locked!
        if @state[:turns] >= @state[:max_turns]
          exceeded!(:model_calls, @state[:max_turns], @state[:turns])
        end
        @state[:turns] += 1
      end
      true
    end

    def charge_usage!(usage)
      unless usage.is_a?(Usage) && usage.input_tokens >= 0 && usage.output_tokens >= 0 &&
             usage.cost_usd.finite? && usage.cost_usd >= 0 && usage.calls >= 0 && usage.duration_ms >= 0
        raise ConfigurationError, "invalid measured execution usage"
      end
      @state[:mutex].synchronize do
        @ancestors.each { |id| @state[:usage][id] += usage }
      end
      @state[:external]&.charge(:llm_usd, usage.cost_usd)
      check!
      usage
    end

    def charge(resource, amount)
      raise ConfigurationError, "unsupported execution budget resource" unless resource.to_sym == :llm_usd
      charge_usage!(Usage.new(cost_usd: amount, calls: 0))
    end

    def check!
      @state[:mutex].synchronize { check_locked! }
      true
    end

    def usage
      @state[:mutex].synchronize { @state[:usage].fetch(@ancestors.last) }
    end

    def remaining_tokens
      @state[:mutex].synchronize { [@state[:max_tokens] - total_usage.total_tokens, 0].max }
    end

    def snapshot
      @state[:mutex].synchronize do
        Harness.deep_freeze(
          limits: @state.slice(:max_turns, :max_tokens, :max_cost_usd),
          admitted_calls: @state[:turns], usage: total_usage.to_h,
          unmeasured_calls: [@state[:turns] - total_usage.calls, 0].max,
          subtree_usage: @state[:usage].fetch(@ancestors.last).to_h,
          unpriced_models: @state[:unpriced].dup
        )
      end
    end

    private

    def priced?(profile)
      rates = LLM::Pricing.for(profile.model) || {}
      [profile.price_in || rates[:input], profile.price_out || rates[:output]].all? do |rate|
        rate.is_a?(Numeric) && rate.finite? && rate >= 0
      end
    end

    def total_usage = @state[:usage].fetch(@ancestors.first)

    def check_locked!
      used = total_usage
      exceeded!(:tokens, @state[:max_tokens], used.total_tokens) if used.total_tokens >= @state[:max_tokens]
      if @state[:max_cost_usd] && used.cost_usd >= @state[:max_cost_usd]
        exceeded!(:llm_usd, @state[:max_cost_usd], used.cost_usd)
      end
    end

    def exceeded!(resource, limit, used)
      raise BudgetExceeded.new(resource: resource, limit: limit, used: used)
    end
  end
end
