# frozen_string_literal: true

module Agentkit
  module LLM
    # Provider ports. Every adapter returns the same normalized hash, so the
    # rest of the kernel never sees a provider SDK.
    module Adapters
      Raw = Struct.new(:content, :input_tokens, :output_tokens, :model, :raw, keyword_init: true)

      def self.build(name)
        case name.to_sym
        when :fake              then Fake.new
        when :ruby_llm          then RubyLLMAdapter.new
        when :openai_compatible then OpenAICompatible.new
        else raise ConfigurationError, "Unknown LLM adapter: #{name}"
        end
      end

      class Base
        def chat(prompt:, model:, system: nil, temperature: nil, max_tokens: nil,
                 timeout: nil, tools: nil, stream: nil)
          raise NotImplementedError
        end

        def embed(texts, model:, dimensions: nil)
          raise NotImplementedError
        end

        # Providers classify their own errors; the LLM layer only distinguishes
        # retryable from permanent.
        def classify(error)
          msg = error.message.to_s.downcase
          return TransientError if msg.match?(/timeout|timed out|rate.?limit|429|50\d|overload|connection|temporarily/)

          PermanentError
        end
      end

      # ─── Fake ────────────────────────────────────────────────────────────────

      # Deterministic adapter shipped with the gem, so domain apps can test
      # without network and without inventing their own doubles.
      #
      # v0.1's spec suite defined its own `module RubyLLM` with a made-up
      # signature; the suite stayed green while the real gem's API had changed,
      # which is how the broken `chat` shipped to five projects.
      class Fake < Base
        Call = Struct.new(:prompt, :system, :model, :temperature, :tools, keyword_init: true)

        class << self
          def script      = @script ||= []
          def failures    = @failures ||= Hash.new(0)
          def calls       = @calls ||= []
          def embed_calls = @embed_calls ||= []

          # Queue canned responses (strings or hashes, consumed in order).
          def respond_with(*responses)
            script.concat(responses.flatten)
            self
          end

          # Make the next `times` calls matching `model`/`contains` fail.
          def fail_on(times: 1, model: nil, contains: nil, error: TransientError)
            failures[[model, contains]] = { remaining: times, error: error }
            self
          end

          def reset!
            @script = []
            @failures = Hash.new(0)
            @calls = []
            @embed_calls = []
            self
          end

          def call_count = calls.size
          def embed_count = embed_calls.sum { |c| c[:texts].size }
        end

        def chat(prompt:, model:, system: nil, temperature: nil, max_tokens: nil,
                 timeout: nil, tools: nil, stream: nil)
          self.class.calls << Call.new(prompt: prompt, system: system, model: model,
                                       temperature: temperature, tools: tools)
          trip_failure!(model, prompt)

          content = next_response(prompt)
          stream&.call(content)
          Raw.new(content: content, model: model,
                  input_tokens: token_estimate(prompt.to_s + system.to_s),
                  output_tokens: token_estimate(content))
        end

        # Deterministic pseudo-embeddings derived from the content hash.
        # `cuatro` stubbed embeddings with `rand`, which makes every recall spec
        # non-reproducible; same content here always yields the same vector, so
        # similarity assertions are stable.
        def embed(texts, model:, dimensions: nil)
          list = Array(texts)
          self.class.embed_calls << { texts: list, model: model }
          dims = dimensions || 1536
          list.map { |t| deterministic_vector(t.to_s, dims) }
        end

        private

        def next_response(prompt)
          value = self.class.script.shift
          return value.is_a?(String) ? value : JSON.generate(value) if value

          "[fake:#{Digest::MD5.hexdigest(prompt.to_s)[0, 8]}]"
        end

        def trip_failure!(model, prompt)
          key = self.class.failures.keys.find do |(m, c)|
            (m.nil? || m.to_s == model.to_s) && (c.nil? || prompt.to_s.include?(c))
          end
          return unless key

          spec = self.class.failures[key]
          return if spec.is_a?(Integer) || spec[:remaining] <= 0

          spec[:remaining] -= 1
          self.class.failures.delete(key) if spec[:remaining] <= 0
          raise spec[:error].new("fake failure", model: model)
        end

        def token_estimate(text) = (text.to_s.length / 4.0).ceil

        def deterministic_vector(text, dims)
          seed = Digest::SHA256.digest(text).unpack("C*")
          vec  = Array.new(dims) { |i| ((seed[i % seed.size] / 255.0) - 0.5) }
          norm = Math.sqrt(vec.sum { |x| x * x })
          norm.zero? ? vec : vec.map { |x| (x / norm).round(6) }
        end
      end

      # ─── ruby_llm ────────────────────────────────────────────────────────────

      # The real API, verified against the gem instead of against a double.
      # v0.1 called `RubyLLM.chat(model:, messages:, system:)`, which does not
      # exist — every project had to patch this same method.
      class RubyLLMAdapter < Base
        def chat(prompt:, model:, system: nil, temperature: nil, max_tokens: nil,
                 timeout: nil, tools: nil, stream: nil)
          require_ruby_llm!

          session = ::RubyLLM.chat(model: model)
          session = session.with_instructions(system) if system && !system.empty?
          session = session.with_temperature(temperature) if temperature && session.respond_to?(:with_temperature)
          session = session.with_tools(*resolve_tools(tools)) if tools && !tools.empty? && session.respond_to?(:with_tools)

          response = stream ? session.ask(prompt) { |chunk| stream.call(chunk.content.to_s) } : session.ask(prompt)

          Raw.new(
            content:       extract_content(response),
            input_tokens:  response.respond_to?(:input_tokens) ? response.input_tokens : dig_tokens(response, :input),
            output_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : dig_tokens(response, :output),
            model:         model,
            raw:           response
          )
        end

        def embed(texts, model:, dimensions: nil)
          require_ruby_llm!

          list = Array(texts)
          args = { model: model }
          args[:dimensions] = dimensions if dimensions
          response = ::RubyLLM.embed(list.size == 1 ? list.first : list, **args)
          vectors  = response.respond_to?(:vectors) ? response.vectors : response
          vectors.first.is_a?(Array) ? vectors : [vectors]
        end

        private

        def require_ruby_llm!
          return if defined?(::RubyLLM)

          raise ConfigurationError, "ruby_llm is not loaded. Add `gem \"ruby_llm\"` or use adapter :fake."
        end

        def extract_content(response)
          return response if response.is_a?(String)

          response.respond_to?(:content) ? response.content : response.to_s
        end

        # Token accounting moved around across ruby_llm versions; probe the
        # shapes we know instead of assuming one.
        def dig_tokens(response, kind)
          if response.respond_to?(:tokens) && response.tokens
            t = response.tokens
            return t.respond_to?(kind) ? t.public_send(kind).to_i : 0
          end
          if response.respond_to?(:usage) && response.usage
            u = response.usage
            key = kind == :input ? :prompt_tokens : :completion_tokens
            return u.respond_to?(key) ? u.public_send(key).to_i : 0
          end
          0
        end

        def resolve_tools(tools)
          Array(tools).map { |t| t.is_a?(Symbol) ? SkillRegistry.tool(t) : t }.compact
        end
      end

      # ─── OpenAI-compatible gateways (Qwen / DashScope / vLLM / Ollama) ───────

      # `tres`, `cuatro` and `totallook` each hand-registered their Qwen models
      # into `RubyLLM.models.all` from an initializer. That belongs in the gem.
      class OpenAICompatible < RubyLLMAdapter
        def chat(**kwargs)
          ensure_configured!
          register_model(kwargs[:model])
          super
        end

        def embed(texts, model:, dimensions: nil)
          ensure_configured!
          register_model(model)
          super
        end

        private

        def ensure_configured!
          require_ruby_llm!
          return if @configured

          cfg = Agentkit.config.llm
          ::RubyLLM.configure do |c|
            c.openai_api_key         = cfg.openai_api_key if c.respond_to?(:openai_api_key=)
            c.openai_api_base        = cfg.api_base if cfg.api_base && c.respond_to?(:openai_api_base=)
            c.openai_use_system_role = true if c.respond_to?(:openai_use_system_role=)
          end
          @configured = true
        end

        def register_model(model_id)
          return if model_id.nil?
          return unless ::RubyLLM.respond_to?(:models)

          models = ::RubyLLM.models
          return if models.any? { |m| m.id == model_id }

          models.all << ::RubyLLM::Model::Info.new(id: model_id, name: model_id, provider: "openai")
        rescue StandardError => e
          Agentkit.logger&.debug("[AgentKit::LLM] model registration skipped: #{e.message}")
        end
      end
    end
  end
end
