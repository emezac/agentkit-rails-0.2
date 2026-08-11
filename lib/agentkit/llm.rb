# frozen_string_literal: true

require_relative "llm/schema"
require_relative "llm/pricing"
require_relative "llm/adapters"

module Agentkit
  # The single door to any model provider.
  #
  # v0.1 had 20 lines inside ApplicationAgent#chat: no retry, no timeout, no
  # structured output, no tools, no fallback, no cost. Everything above that
  # line was re-implemented by each project.
  module LLM
    Response = Struct.new(:content, :parsed, :usage, :model, :profile, :cached,
                          :attempts, :fallback_used, keyword_init: true) do
      def cached?        = !!cached
      def fallback_used? = !!fallback_used
      def to_s           = content.to_s
    end

    class << self
      def adapter
        @adapter ||= Adapters.build(Agentkit.config.llm.adapter)
      end

      attr_writer :adapter

      def reset!
        @adapter = nil
        @breakers = {}
        Adapters::Fake.reset!
        self
      end

      # Main entry point.
      #
      # @param model  [Symbol, String, Array] profile name, explicit model id, or
      #   a chain of profiles tried in order.
      # @param schema [Schema, nil] when given, the reply is parsed and validated;
      #   a violation triggers a re-ask before raising SchemaViolation.
      def complete(prompt, model: :default, system: nil, temperature: nil, max_tokens: nil,
                   timeout: nil, tools: nil, schema: nil, cache: nil, stream: nil,
                   agent: nil, prompt_id: nil, prompt_version: nil,
                   experiment_id: nil, experiment_arm: nil)
        # `Array(nil)` is empty, so an explicit `model: nil` (what Agent#complete
        # passes when no profile is chosen) must fall back to :default rather
        # than skipping the loop and raising "no profile could serve".
        chain = Array(model).compact
        chain = [:default] if chain.empty?
        last_error = nil

        chain.each_with_index do |candidate, index|
          profile = ModelRouter.profile_for(candidate)
          next if circuit_open?(profile.provider) && index < chain.size - 1

          begin
            return call_with_retries(
              prompt: prompt, profile: profile, profile_name: candidate, system: system,
              temperature: temperature, max_tokens: max_tokens, timeout: timeout,
              tools: tools, schema: schema, cache: cache, stream: stream, agent: agent,
              prompt_id: prompt_id, prompt_version: prompt_version,
              experiment_id: experiment_id, experiment_arm: experiment_arm,
              fallback_used: index.positive?
            )
          rescue PermanentError, CircuitOpen => e
            last_error = e
            fallback = ModelRouter.fallback_for(candidate)
            chain << fallback if fallback && !chain.include?(fallback)
            next
          end
        end

        raise last_error || PermanentError.new("No model profile could serve the request")
      end

      # Embeddings. Batched by construction — the caller passes an array.
      def embed(texts, model: nil, dimensions: nil)
        list  = Array(texts)
        return [] if list.empty?

        cfg   = Agentkit.config.memory.embedding
        model ||= cfg.model
        dims  = dimensions || cfg.dimensions

        Telemetry.measure("embedding.generate",
                          dims: { model: model, batched: list.size > 1 },
                          measures: { count: list.size }) do |m|
          vectors = adapter.embed(list, model: model, dimensions: dims)
          tokens  = list.sum { |t| (t.to_s.length / 4.0).ceil }
          m[:tokens]   = tokens
          m[:cost_usd] = Pricing.cost(model: model, input_tokens: tokens, output_tokens: 0)
          vectors
        end
      end

      # ─── Circuit breaker ─────────────────────────────────────────────────────

      def breakers
        @breakers ||= {}
      end

      def circuit_open?(provider)
        state = breakers[provider]
        return false if state.nil? || state[:failures] < Agentkit.config.llm.breaker_threshold

        if Time.now - state[:opened_at] > Agentkit.config.llm.breaker_cooldown
          breakers[provider] = { failures: 0, opened_at: nil } # half-open: let one through
          return false
        end
        true
      end

      private

      def call_with_retries(prompt:, profile:, profile_name:, system:, temperature:, max_tokens:,
                            timeout:, tools:, schema:, cache:, stream:, agent:,
                            prompt_id:, prompt_version:, experiment_id:, experiment_arm:,
                            fallback_used:)
        cfg      = Agentkit.config.llm
        attempts = 0
        started  = monotonic
        system   = augment_system(system, schema)

        begin
          attempts += 1
          raise CircuitOpen.new("circuit open for #{profile.provider}", provider: profile.provider) if circuit_open?(profile.provider) && attempts == 1

          raw = adapter.chat(
            prompt:      prompt,
            model:       profile.model,
            system:      system,
            temperature: temperature || profile.temperature,
            max_tokens:  max_tokens || profile.max_tokens,
            timeout:     timeout || profile.timeout || cfg.timeout,
            tools:       tools,
            stream:      stream,
            api_base:    profile.api_base,
            api_key:     profile.api_key
          )
          record_success(profile.provider)
        rescue StandardError => e
          error = normalize_error(e, profile)
          record_failure(profile.provider) if error.is_a?(TransientError)

          if error.is_a?(TransientError) && attempts <= cfg.retries
            sleep(backoff_delay(attempts))
            retry
          end
          emit_call(profile: profile, profile_name: profile_name, agent: agent, usage: nil,
                    attempts: attempts, status: "error", error: error, prompt: prompt,
                    prompt_id: prompt_id, prompt_version: prompt_version,
                    experiment_id: experiment_id, experiment_arm: experiment_arm,
                    started: started)
          raise error
        end

        usage = build_usage(raw, profile, started)
        parsed, violations = parse_with_schema(raw.content, schema)

        # One re-ask with the violations spelled out before giving up. This is
        # what replaces the hand-rolled `parse_json` + regex fallback that four
        # projects wrote independently.
        if schema && violations.any? && attempts <= cfg.schema_retries + 1
          repaired = complete(
            repair_prompt(raw.content, violations, schema),
            model: profile.model, system: system, temperature: 0.0, agent: agent,
            prompt_id: prompt_id, prompt_version: prompt_version,
            experiment_id: experiment_id, experiment_arm: experiment_arm
          )
          parsed, violations = parse_with_schema(repaired.content, schema)
          usage += repaired.usage
          raw = Adapters::Raw.new(content: repaired.content, model: profile.model,
                                  input_tokens: 0, output_tokens: 0)
        end

        if schema && violations.any?
          emit_call(profile: profile, profile_name: profile_name, agent: agent, usage: usage,
                    attempts: attempts, status: "schema_violation", prompt: prompt,
                    prompt_id: prompt_id, prompt_version: prompt_version, started: started,
                    experiment_id: experiment_id, experiment_arm: experiment_arm,
                    violations: violations.size)
          raise SchemaViolation.new("LLM output failed schema: #{violations.join('; ')}",
                                    raw: raw.content, violations: violations)
        end

        emit_call(profile: profile, profile_name: profile_name, agent: agent, usage: usage,
                  attempts: attempts, status: "ok", prompt: prompt, prompt_id: prompt_id,
                  prompt_version: prompt_version, experiment_id: experiment_id,
                  experiment_arm: experiment_arm, started: started,
                  fallback_used: fallback_used)

        charge_budget(usage)

        Response.new(content: raw.content, parsed: parsed, usage: usage, model: profile.model,
                     profile: profile_name, cached: false, attempts: attempts,
                     fallback_used: fallback_used)
      end

      def augment_system(system, schema)
        return system unless schema

        [system, schema.prompt_fragment].compact.reject(&:empty?).join("\n\n")
      end

      def parse_with_schema(content, schema)
        return [nil, []] unless schema

        extracted = Schema.extract(content)
        return [nil, ["response was not valid JSON"]] if extracted.nil?

        coerced = schema.coerce(extracted)
        [coerced, schema.validate(coerced)]
      end

      def repair_prompt(raw, violations, schema)
        <<~TXT
          Your previous answer did not satisfy the required format.

          Previous answer:
          #{raw.to_s.slice(0, 2000)}

          Problems:
          #{violations.map { |v| "- #{v}" }.join("\n")}

          Return ONLY a corrected JSON object satisfying:
          #{JSON.pretty_generate(schema.to_json_schema)}
        TXT
      end

      def build_usage(raw, profile, started)
        Usage.new(
          input_tokens:  raw.input_tokens.to_i,
          output_tokens: raw.output_tokens.to_i,
          duration_ms:   ((monotonic - started) * 1000).round,
          model:         profile.model,
          cost_usd:      Pricing.cost(model: profile.model,
                                      input_tokens: raw.input_tokens.to_i,
                                      output_tokens: raw.output_tokens.to_i,
                                      price_in: profile.price_in, price_out: profile.price_out)
        )
      end

      def emit_call(profile:, profile_name:, agent:, usage:, attempts:, status:, started:,
                    prompt: nil, prompt_id: nil, prompt_version: nil, error: nil,
                    experiment_id: nil, experiment_arm: nil,
                    violations: 0, fallback_used: false)
        # Immutable row with the prompt preview — this is what v0.1 stored in
        # agentkit_agent_logs and what an auditor actually needs to see.
        Audit.record(
          event_type: "llm.call", agent_name: agent, status: status, prompt: prompt,
          model: profile.model, usage: usage,
          payload: { profile: profile_name, provider: profile.provider,
                     prompt_id: prompt_id, prompt_version: prompt_version,
                     experiment_id: experiment_id, experiment_arm: experiment_arm,
                     attempts: attempts, schema_violations: violations,
                     fallback_used: fallback_used, error: error&.message }
        )
        Telemetry.emit(
          "llm.call",
          dims: {
            model: profile.model, provider: profile.provider, profile: profile_name,
            agent: agent, prompt_id: prompt_id, prompt_version: prompt_version,
            experiment_id: experiment_id, experiment_arm: experiment_arm,
            status: status, error_class: error&.class&.name
          },
          measures: {
            input_tokens: usage&.input_tokens || 0, output_tokens: usage&.output_tokens || 0,
            cost_usd: usage&.cost_usd || 0.0,
            duration_ms: usage&.duration_ms || ((monotonic - started) * 1000).round,
            retries: attempts - 1, schema_violations: violations,
            fallback_used: fallback_used
          }
        )
      end

      def charge_budget(usage)
        budget = Context.current&.budget
        budget&.charge(:llm_usd, usage.cost_usd)
      end

      def normalize_error(error, profile)
        return error if error.is_a?(LLMError)

        klass = adapter.classify(error)
        klass.new("#{error.class}: #{error.message}", provider: profile.provider, model: profile.model)
      end

      def backoff_delay(attempt)
        base = Agentkit.config.llm.backoff_base
        (base * (2**(attempt - 1))) * (0.5 + Kernel.rand)
      end

      def record_failure(provider)
        state = breakers[provider] ||= { failures: 0, opened_at: nil }
        state[:failures] += 1
        state[:opened_at] = Time.now if state[:failures] >= Agentkit.config.llm.breaker_threshold
      end

      def record_success(provider)
        breakers[provider] = { failures: 0, opened_at: nil }
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
