# frozen_string_literal: true

module Agentkit
  module LLM
    module Adapters
      RawTurn = Struct.new(:message, :input_tokens, :output_tokens, :model, :stop_reason, keyword_init: true)

      class Base
        def turn(**)
          raise ConfigurationError, "this LLM adapter does not support single-turn tool proposals"
        end
      end

      class Fake
        TurnCall = Struct.new(:messages, :tools, :model, :api_base, :api_key, :max_tokens, keyword_init: true)
        class << self
          def turn_script = @turn_script ||= []
          def turn_calls = @turn_calls ||= []
          def respond_with_turns(*turns)
            turn_script.concat(turns)
            self
          end

          alias reset_before_turns! reset!
          def reset!
            reset_before_turns!
            @turn_script, @turn_calls = [], []
            self
          end
        end

        def turn(messages:, tools:, model:, max_tokens:, temperature: nil, timeout: nil, api_base: nil, api_key: nil, thinking: nil)
          call = TurnCall.new(messages: messages, tools: tools, model: model,
                              api_base: api_base, api_key: api_key, max_tokens: max_tokens)
          self.class.turn_calls << call
          self.class.calls << call
          data = self.class.turn_script.shift || { content: "[fake answer]" }
          raise data if data.is_a?(Exception)
          data = Harness.stringify_keys(data)
          calls = data.fetch("tool_calls", [])
          message = { "role" => "assistant", "content" => data.fetch("content", ""), "tool_calls" => calls }
          message["thinking"] = data["thinking"] if data["thinking"]
          RawTurn.new(
            message: message, model: model, stop_reason: data["stop_reason"] || (calls.empty? ? "answered" : "tool_calls"),
            input_tokens: data.fetch("input_tokens", (JSON.generate(messages).bytesize / 4.0).ceil),
            output_tokens: data.fetch("output_tokens", (JSON.generate(message).bytesize / 4.0).ceil)
          )
        end
      end

      class RubyLLMAdapter
        # Schema-only objects: even accidental SDK invocation cannot execute code.
        NativeTool = Struct.new(:name, :description, :params_schema, keyword_init: true) do
          def provider_params = {}
          def parameters = {}
          def call(*) = raise(ConfigurationError, "single-turn schemas cannot execute tools")
        end

        def turn(messages:, tools:, model:, max_tokens:, temperature: nil, timeout: nil, api_base: nil, api_key: nil, thinking: nil)
          require_ruby_llm!
          unless defined?(::RubyLLM::VERSION) &&
                 Gem::Version.new(::RubyLLM::VERSION) >= Gem::Version.new("1.15.0") &&
                 Gem::Version.new(::RubyLLM::VERSION) < Gem::Version.new("2.0")
            raise ConfigurationError, "single-turn proposals require ruby_llm >= 1.15 and < 2"
          end
          cfg = ::RubyLLM.context do |config|
            application = Context.resolve.config.llm
            config.anthropic_api_key = application.anthropic_api_key if application.anthropic_api_key
            config.openai_api_key = application.openai_api_key if application.openai_api_key
            if application.google_api_key && config.respond_to?(:gemini_api_key=)
              config.gemini_api_key = application.google_api_key
            end
            config.request_timeout = timeout if timeout
            config.max_retries = 0
            if api_base || api_key
              config.openai_api_base = api_base if api_base
              config.openai_api_key = api_key if api_key
              config.openai_use_system_role = true
            end
          end.config
          info, provider = if api_base || api_key
                             ::RubyLLM::Models.resolve(model, provider: "openai", assume_exists: true, config: cfg)
                           else
                             ::RubyLLM::Models.resolve(model, config: cfg)
                           end
          native_messages = messages.map do |message|
            attrs = message.transform_keys(&:to_sym)
            calls = Array(message["tool_calls"]).to_h do |call|
              [call.fetch("id"), ::RubyLLM::ToolCall.new(**call.transform_keys(&:to_sym))]
            end
            attrs[:tool_calls] = calls unless calls.empty?
            attrs[:thinking] = ::RubyLLM::Thinking.new(**attrs[:thinking].transform_keys(&:to_sym)) if attrs[:thinking]
            if provider.slug.to_s == "anthropic" && message["provider_blocks"]
              attrs[:content] = ::RubyLLM::Content::Raw.new(message["provider_blocks"])
              attrs.delete(:thinking)
            end
            # Preserve signed Anthropic blocks even if the current request did
            # not explicitly enable thinking (some models emit it themselves).
            if provider.slug.to_s == "anthropic" && message["thinking"] && !message["provider_blocks"]
              thought = message.fetch("thinking")
              block = { type: "thinking", thinking: thought["text"].to_s, signature: thought["signature"] }.compact
              blocks = [block]
              blocks << { type: "text", text: message["content"] } unless message["content"].to_s.empty?
              calls.each_value { |call| blocks << { type: "tool_use", id: call.id, name: call.name, input: call.arguments } }
              attrs[:content] = ::RubyLLM::Content::Raw.new(blocks)
              attrs.delete(:thinking)
            end
            ::RubyLLM::Message.new(attrs)
          end
          native_tools = tools.to_h do |tool|
            [tool.fetch("name").to_sym, NativeTool.new(name: tool.fetch("name"),
              description: tool.fetch("description"), params_schema: tool.fetch("input_schema"))]
          end
          params = provider.slug.to_s == "anthropic" ? { max_tokens: max_tokens } : { max_completion_tokens: max_tokens }
          reasoning = thinking && ::RubyLLM::Thinking::Config.new(**thinking.transform_keys(&:to_sym))
          response = provider.complete(native_messages, tools: native_tools,
            tool_prefs: { choice: nil, calls: :many }, temperature: temperature, model: info, params: params,
            thinking: reasoning)
          unless response && (response.content.nil? || response.content.is_a?(String))
            raise AgentLoopProtocolError, "single-turn adapter requires text responses"
          end
          data = response.raw&.body || {}
          reason = data["stop_reason"] || data.dig("choices", 0, "finish_reason")
          reason = "refusal" if data.dig("choices", 0, "message", "refusal")
          calls = (response.tool_calls || {}).values.map { |call| Harness.stringify_keys(call.to_h) }
          stop = case reason
                 when "length", "max_tokens" then "max_tokens"
                 when "content_filter", "refusal" then "refusal"
                 when "tool_calls", "tool_use", "function_call" then "tool_calls"
                 when "stop", "end_turn", "stop_sequence" then "answered"
                 else "unsupported_stop"
                 end
          # A provider may return proposed tools alongside a truncated response;
          # the loop will stop before executing any such batch.
          stop = "max_tokens" if %w[length max_tokens].include?(reason)
          message = { "role" => "assistant", "content" => response.content.to_s, "tool_calls" => calls }
          message["provider_blocks"] = data["content"] if provider.slug.to_s == "anthropic"
          if response.thinking
            message["thinking"] = { "text" => response.thinking.text, "signature" => response.thinking.signature }
          end
          input = response.input_tokens
          total_input = input && input + response.cached_tokens.to_i + response.cache_creation_tokens.to_i
          RawTurn.new(message: message, model: model, input_tokens: total_input,
                      output_tokens: response.output_tokens, stop_reason: stop)
        end
      end

      class OpenAICompatible
        def turn(**kwargs)
          config = Context.resolve.config.llm
          kwargs[:api_base] ||= config.api_base
          kwargs[:api_key] ||= config.openai_api_key
          super(**kwargs)
        end
      end
    end
  end
end
