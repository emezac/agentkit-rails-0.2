# frozen_string_literal: true

require "spec_helper"

# Regression spec for the traceability v0.1 had and an early v2 draft dropped.
#
# v0.1's `agentkit_agent_logs` stored the full payload plus a 500-character
# prompt preview and was documented as "immutable audit log, never modified
# after creation". Routing that through Telemetry silently discarded every
# non-numeric field and let the record expire after 90 days.
RSpec.describe Agentkit::Audit do
  let(:agent_class) do
    Class.new(Agentkit::Agent) do
      def self.name = "AuditedAgent"
      def call(text)
        agent_log(event: :started, payload: { "brief" => text, "attempt" => 1 })
        result = chat("analyse: #{text}")
        agent_log(event: :completed, payload: { "outcome" => result, "score" => 0.8 })
        result
      end
    end
  end

  describe "agent_log keeps the whole payload (v0.1 parity)" do
    it "stores non-numeric fields instead of dropping them" do
      agent_class.new.call("cliente Acme se retrasó")

      entries = described_class.entries(agent: "AuditedAgent")
      started = entries.find { |e| e.event_type == "started" }

      expect(started.payload["brief"]).to eq("cliente Acme se retrasó")
      expect(started.payload["attempt"]).to eq(1)
      expect(entries.map(&:event_type)).to include("started", "completed")
    end

    it "still emits the numeric measures to telemetry" do
      agent_class.new.call("x")
      expect(emitted("agent.completed").last.measures[:score]).to eq(0.8)
    end
  end

  describe "prompt preview" do
    it "captures what was actually sent to the model" do
      Agentkit.config.audit.prompt_preview_chars = 500
      Agentkit::LLM.complete("analiza el contrato de Acme", model: :default, agent: "SomeAgent")

      entry = described_class.entries(event_type: "llm.call").last
      expect(entry.prompt_preview).to include("analiza el contrato de Acme")
      expect(entry.model).to eq(Agentkit.config.llm.profiles[:default].model)
      expect(entry.cost_usd).to be_a(Float)
    end

    it "truncates to the configured length" do
      Agentkit.config.audit.prompt_preview_chars = 20
      Agentkit::LLM.complete("x" * 500)

      expect(described_class.entries(event_type: "llm.call").last.prompt_preview.length).to eq(20)
    end

    it "can be disabled entirely for sensitive domains" do
      Agentkit.config.audit.prompt_preview_chars = 0
      Agentkit::LLM.complete("datos muy sensibles")

      expect(described_class.entries(event_type: "llm.call").last.prompt_preview).to be_nil
    end

    it "redacts emails, card-like numbers and api keys before storing" do
      Agentkit.config.audit.prompt_preview_chars = 500
      Agentkit::LLM.complete("escribile a juan@acme.com con la tarjeta 4111 1111 1111 1111")

      preview = described_class.entries(event_type: "llm.call").last.prompt_preview
      expect(preview).to include("[REDACTED]")
      expect(preview).not_to include("juan@acme.com")
      expect(preview).not_to include("4111")
    end

    it "is disabled by default" do
      Agentkit::LLM.complete("un prompt privado")

      expect(described_class.entries(event_type: "llm.call").last.prompt_preview).to be_nil
    end
  end

  describe "audit is not telemetry" do
    it "is never sampled away" do
      Agentkit.config.telemetry.sampling = { "agent.started" => 0.0 }

      agent_class.new.call("importante")

      expect(emitted("agent.started")).to be_empty          # telemetry sampled out
      expect(described_class.entries(event_type: "started")).not_to be_empty # audit intact
    end

    it "survives with telemetry switched off entirely" do
      Agentkit.config.telemetry.enabled = false

      agent_class.new.call("sigue auditado")

      expect(described_class.entries(agent: "AuditedAgent")).not_to be_empty
    end

    it "never breaks the action it records" do
      allow(described_class.store).to receive(:append).and_raise("audit store down")

      expect { agent_class.new.call("x") }.not_to raise_error
      expect(emitted("audit.write_failed")).not_to be_empty
    end

    it "fails closed when evidence is required" do
      allow(described_class.store).to receive(:append).and_raise("audit store down")

      expect do
        described_class.record(event_type: "security.decision", failure_mode: :required)
      end.to raise_error(Agentkit::AuditPersistenceError, /request_id=/)
    end

    it "fails closed when required evidence has been disabled" do
      Agentkit.config.audit.enabled = false

      expect do
        described_class.record(event_type: "security.decision", failure_mode: :required)
      end.to raise_error(Agentkit::AuditPersistenceError, /request_id=/)
    end

    it "redacts sensitive keys recursively" do
      described_class.record(
        event_type: "tool.call",
        payload: { request: { headers: { authorization: "Bearer secret" } },
                   items: [{ "api-key" => "sk-super-secret-value" }] }
      )

      payload = described_class.entries(event_type: "tool.call").last.payload
      expect(payload.dig("request", "headers", "authorization")).to eq("[REDACTED]")
      expect(payload.dig("items", 0, "api-key")).to eq("[REDACTED]")
    end
  end

  describe "correlation" do
    it "ties every entry to the run and trace it happened in" do
      ctx = Agentkit::Context.new(run_id: "11111111-1111-1111-1111-111111111111")

      Agentkit.with_context(ctx) { agent_class.new.call("correlacionado") }

      entries = described_class.entries(run_id: ctx.run_id)
      expect(entries).not_to be_empty
      expect(entries.map(&:trace_id).uniq).to eq([ctx.trace_id])
    end

    it "builds a timeline for a correlation id" do
      ctx = Agentkit::Context.new
      Agentkit.with_context(ctx) { agent_class.new.call("linea de tiempo") }

      timeline = described_class.timeline(ctx.trace_id)
      expect(timeline[:entries].size).to be >= 3   # started + llm.call + completed
      expect(timeline[:entries].map(&:occurred_at)).to eq(timeline[:entries].map(&:occurred_at).sort)
    end
  end

  describe "cognitive traces survive the process" do
    before do
      Agentkit.config.memory.embedding.policy = :immediate
      Agentkit::Memory.store("El SRE reportó latencia alta", tags: %w[sre])
      Agentkit::Memory.store("Fraude vio picos de chargeback", tags: %w[fraude])
      Agentkit::Memory.store("Soporte reporta checkout lento", tags: %w[soporte])
      fake_llm.respond_with(
        { ideas: [{ concept: "checkout adaptativo", description: "ruteo por latencia", originality: 0.9 }] },
        { practical_application: "Ruteo dinámico del checkout por región",
          innovation_score: 0.9, relevance_score: 0.8, confidence: 0.8 }
      )
    end

    it "persists the phases of an imagination run to the audit store" do
      Agentkit::Cognition.run(:imagination)

      trace = described_class.traces_for(kind: "imagination").last
      expect(trace).not_to be_nil
      expect(trace.phases.map { |p| p[:name] })
        .to include("divergent_extraction", "incubation", "practicality_gate", "verification")
      expect(trace.status).to eq("completed")
      expect(trace.duration_ms).to be >= 0
    end

    it "makes an imagined scenario explainable through its trace" do
      Agentkit::Cognition.run(:imagination)

      scenario = Agentkit::Memory.all(ontological: %w[imagined]).first
      provenance = described_class.provenance(scenario)

      expect(provenance[:ontological]).to eq("imagined")
      expect(provenance[:sources]).to be_an(Array)
      expect(provenance[:trace][:kind]).to eq("imagination")
      # The extraction phase records exactly which memories fed the hypothesis.
      extraction = provenance[:trace][:phases].find { |p| p[:name] == "divergent_extraction" }
      expect(extraction[:ids]).to eq(provenance[:sources])
    end

    it "records a dreaming consolidation with the cluster that produced it" do
      fake_llm.respond_with("Los tres equipos ven el mismo cuello de botella.")
      Agentkit.config.memory.dreaming.min_recalls = 0

      Agentkit::Cognition.run(:dreaming, threshold: 0.95, min_cluster: 2)

      trace = described_class.traces_for(kind: "dreaming").last
      consolidated = trace.phases.select { |p| p[:name] == "consolidated" }
      expect(consolidated).not_to be_empty
      expect(consolidated.first[:cluster]).to be_an(Array)   # source memory ids
      expect(consolidated.first[:insight]).to be_truthy      # resulting memory id
    end

    it "keeps the trace id joinable from the memory it produced" do
      Agentkit::Cognition.run(:imagination)

      scenario = Agentkit::Memory.all(ontological: %w[imagined]).first
      trace_id = scenario.metadata["trace_id"]

      expect(described_class.find_trace(trace_id)).not_to be_nil
    end
  end

  describe "provenance of a consolidated memory" do
    it "reports what superseded what" do
      Agentkit.config.memory.embedding.policy = :never
      old = Agentkit::Memory.store("observación vieja")
      insight = Agentkit::Memory.store("el insight", type: "insight")
      Agentkit::Memory.supersede!([old], by: insight)

      expect(described_class.provenance(Agentkit::Memory.find(old.id))[:superseded_by]).to eq(insight.id)
    end
  end
end
