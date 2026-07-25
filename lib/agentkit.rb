# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"

require_relative "agentkit/version"
require_relative "agentkit/errors"
require_relative "agentkit/settings"
require_relative "agentkit/configuration"
require_relative "agentkit/context"
require_relative "agentkit/result"

require_relative "agentkit/telemetry"
require_relative "agentkit/audit"
require_relative "agentkit/llm"
require_relative "agentkit/prompt"
require_relative "agentkit/model_router"
require_relative "agentkit/skill"

require_relative "agentkit/memory"
require_relative "agentkit/hitl"
require_relative "agentkit/flow"
require_relative "agentkit/agent"
require_relative "agentkit/cognition"
require_relative "agentkit/capability"
require_relative "agentkit/setup"
require_relative "agentkit/proposals"
require_relative "agentkit/a2a"
require_relative "agentkit/factory"

# AgentKit Rails v2 — agent kernel for domain applications.
#
# The core (everything under lib/) is plain Ruby with no Rails dependency, so it
# can be unit-tested without a database and reused outside Rails. The Rails
# engine (app/, db/) plugs ActiveRecord-backed stores into the same ports.
#
#   Agentkit.configure do |config|
#     config.domain_name  = "Astra"
#     config.memory.level = :hybrid
#     config.memory.embedding.policy = :on_promotion
#   end
module Agentkit
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield(config) if block_given?
      validate!
      config
    end

    # Replace the whole configuration (tests, multi-app hosts).
    attr_writer :config

    def reset!
      @config = Configuration.new
      Telemetry.reset!
      Audit.reset!
      Prompt.reset!
      SkillRegistry.reset!
      Capability.reset!
      Memory.reset!
      HITL.reset!
      Flow::Registry.reset!
      self
    end

    def validate!
      problems = config.validate
      raise ConfigurationError, "Invalid AgentKit configuration:\n  - #{problems.join("\n  - ")}" if problems.any?

      true
    end

    # ─── Context ─────────────────────────────────────────────────────────────

    def context = Context.resolve

    def with_context(ctx_or_attrs, &block)
      ctx = ctx_or_attrs.is_a?(Context) ? ctx_or_attrs : Context.new(**ctx_or_attrs)
      Context.with(ctx, &block)
    end

    # ─── Telemetry shortcuts ─────────────────────────────────────────────────

    # Domain probe. Everything the kernel does is already instrumented; this is
    # for business measures the kernel cannot know about.
    #
    #   Agentkit.probe(:lead_qualified, value: 1, dims: { source: "outreach" })
    def probe(name, value: 1, dims: {}, **measures)
      Telemetry.emit(name, dims: dims, measures: measures.merge(value: value))
    end

    # Late-arriving business outcome attached to a decision/proposal. Without
    # this the factory can only optimise proxies, never real value.
    def outcome(name, for:, value: nil, within: nil, **dims)
      subject    = binding.local_variable_get(:for)
      subject_id = subject.respond_to?(:id) ? subject.id : nil
      Telemetry.emit(
        "outcome.#{name}",
        dims: dims.merge(subject_type: subject.class.name, subject_id: subject_id),
        measures: { value: value.respond_to?(:call) ? value.call : value, within: within }
      )
    end

    def logger
      @logger ||= defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : default_logger
    end

    attr_writer :logger

    private

    def default_logger
      require "logger"
      ::Logger.new($stdout, level: ::Logger::WARN)
    end
  end
end

require_relative "agentkit/engine" if defined?(::Rails::Engine)
