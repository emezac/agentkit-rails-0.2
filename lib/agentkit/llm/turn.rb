# frozen_string_literal: true

require_relative "turn_adapters"

module Agentkit
  module LLM
    Turn = Struct.new(:message, :usage, :stop_reason, :model, keyword_init: true)

    class << self
      # Exactly one model request. Providers return proposals; only AgentLoop
      # executes tools. No SDK recursion, automatic fallback or hidden retry.
      def turn(messages:, tools:, model: :default, max_tokens: 2_048, temperature: nil, agent: nil)
        unless max_tokens.is_a?(Integer) && max_tokens.positive?
          raise ConfigurationError, "turn max_tokens must be a positive integer"
        end
        profile = ModelRouter.profile_for(model)
        budget = Context.current&.budget
        budget&.admit_model!(profile) if budget.respond_to?(:admit_model!)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        usage = nil
        status = "error"
        raw = adapter.turn(
          messages: messages, tools: tools, model: profile.model,
          max_tokens: max_tokens, temperature: temperature || profile.temperature,
          timeout: profile.timeout || Agentkit.config.llm.timeout,
          thinking: profile.thinking,
          api_base: profile.api_base, api_key: profile.api_key
        )
        unless [raw.input_tokens, raw.output_tokens].all? { |count| count.is_a?(Integer) && count >= 0 }
          raise AgentLoopProtocolError, "turn usage must include nonnegative token counts"
        end
        usage = build_usage(raw, profile, started)
        charge_budget(usage)
        if JSON.generate(raw.message).bytesize > Context.resolve.config.agent_loop.max_response_bytes
          raise AgentLoopLimitExceeded, "model turn exceeds response byte limit"
        end
        message = normalize_turn_message(raw.message)
        unless %w[answered tool_calls max_tokens refusal unsupported_stop].include?(raw.stop_reason)
          raise AgentLoopProtocolError, "unknown model stop reason"
        end
        if (raw.stop_reason == "tool_calls" && message.fetch("tool_calls").empty?) ||
           (raw.stop_reason == "answered" && message.fetch("tool_calls").any?)
          raise AgentLoopProtocolError, "model stop reason contradicts tool calls"
        end
        status = "ok"
        Turn.new(message: message, usage: usage, stop_reason: raw.stop_reason, model: profile.model).freeze
      ensure
        if started
          Audit.record(event_type: "llm.turn", agent_name: agent, status: status,
                       model: profile.model, usage: usage,
                       payload: { model: profile.model, status: status })
          Telemetry.emit("llm.turn", dims: { model: profile.model, agent: agent, status: status },
                         measures: { input_tokens: usage&.input_tokens || 0,
                                     output_tokens: usage&.output_tokens || 0, cost_usd: usage&.cost_usd || 0,
                                     duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round })
        end
      end

      private

      def normalize_turn_message(raw)
        data = Harness::DeclarativeData.normalize(raw, label: "model turn", error_class: AgentLoopProtocolError)
        unless data.is_a?(Hash) && data["role"] == "assistant" &&
               data["content"].is_a?(String) && data["tool_calls"].is_a?(Array)
          raise AgentLoopProtocolError, "turn must be an assistant text/tool-call message"
        end
        ids = []
        calls = data["tool_calls"].map do |call|
          unless call.is_a?(Hash) && call["id"].is_a?(String) && call["id"].bytesize.between?(1, 128) &&
                 call["name"].is_a?(String) && call["name"].match?(/\A[a-zA-Z0-9_-]{1,64}\z/) &&
                 call["arguments"].is_a?(Hash) && !ids.include?(call["id"]) &&
                 (call["thought_signature"].nil? || call["thought_signature"].is_a?(String))
            raise AgentLoopProtocolError, "malformed or duplicate tool call"
          end
          ids << call["id"]
          call.slice("id", "name", "arguments", "thought_signature")
        end
        result = { "role" => "assistant", "content" => data["content"], "tool_calls" => calls }
        if data["provider_blocks"]
          unless data["provider_blocks"].is_a?(Array) && data["provider_blocks"].all? { |block|
            block.is_a?(Hash) && %w[text tool_use thinking redacted_thinking].include?(block["type"])
          }
            raise AgentLoopProtocolError, "unsupported provider content blocks"
          end
          result["provider_blocks"] = data["provider_blocks"]
        end
        if data["thinking"]
          unless data["thinking"].is_a?(Hash) &&
                 data["thinking"].values.all? { |value| value.nil? || value.is_a?(String) }
            raise AgentLoopProtocolError, "malformed provider thinking metadata"
          end
          result["thinking"] = data["thinking"].slice("text", "signature")
        end
        Harness.deep_freeze(result)
      end
    end
  end
end
