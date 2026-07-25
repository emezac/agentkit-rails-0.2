# frozen_string_literal: true

module Agentkit
  class FactoryController < ApplicationController
    def index
      @mode        = Agentkit.config.factory.mode
      @findings    = Agentkit::Factory.findings.select { |f| f.status == "open" }
      @experiments = Agentkit::Factory.experiments
      @ledger      = Agentkit::HITL.ledger
      @since       = Time.now - window
      @agents      = @ledger.entries(since: @since).map(&:agent_name).compact.uniq
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
      {
        llm_spend:  Agentkit::Telemetry.events(name: "llm.call", since: since)
                                       .sum { |e| e.measures[:cost_usd].to_f },
        embeddings: Agentkit::Telemetry.events(name: "embedding.generate", since: since)
                                       .sum { |e| e.measures[:count].to_i },
        latency:    Agentkit::Telemetry.stats("llm.call", measure: :duration_ms, since: since)
      }
    end
  end
end
