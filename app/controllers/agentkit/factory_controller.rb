# frozen_string_literal: true

module Agentkit
  class FactoryController < ApplicationController
    def index
      @mode        = Agentkit.config.factory.mode
      @findings    = Agentkit::Factory.findings.select { |f| f.status == "open" }
      @experiments = Agentkit::Factory.experiments
      @ledger      = Agentkit::HITL.ledger
      @since       = Time.now - window
      @scope       = Agentkit::Scope.resolve(context: agentkit_context)
      @agents      = @ledger.entries(since: @since, scope: @scope).map(&:agent_name).compact.uniq
      @economics   = economics
    end

    def diagnose
      Agentkit::Factory.capture_golden!
      found = Agentkit::Factory.diagnose!(window: window)
      redirect_to factory_path, notice: "#{found.size} hallazgos nuevos"
    end

    def report
      send_data Agentkit::Factory.report(window: window),
                filename: "agentkit-factory-#{Date.today}.md", type: "text/markdown"
    end

    private

    def economics
      since = Time.now - window
      tenant = @scope&.tenant_key || Agentkit::Scope.resolve(context: agentkit_context).tenant_key
      llm_events = Agentkit::Telemetry.events(name: "llm.call", since: since)
                                      .select { |event| tenant.nil? || event.dims[:tenant].to_s == tenant.to_s }
      embedding_events = Agentkit::Telemetry.events(name: "embedding.generate", since: since)
                                            .select { |event| tenant.nil? || event.dims[:tenant].to_s == tenant.to_s }
      {
        llm_spend:  llm_events.sum { |e| e.measures[:cost_usd].to_f },
        embeddings: embedding_events.sum { |e| e.measures[:count].to_i },
        latency:    Agentkit::Telemetry::Stats.from(llm_events.filter_map { |e| e.measures[:duration_ms] })
      }
    end
  end
end
