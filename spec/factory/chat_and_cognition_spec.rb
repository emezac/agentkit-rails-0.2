# frozen_string_literal: true

RSpec.describe Agentkit::Chat do
  let(:acme)    { AgentkitSpecHelpers::Company.new(1, "Acme", "saas", "latam", 120) }
  let(:offtopic) { AgentkitSpecHelpers::Company.new(2, "Ferretería Díaz", "retail", "eu", 8) }

  before do
    Agentkit::Setup.define do
      field :objective, type: :enum, values: %i[growth retention], required: true
      field :icp,       type: :struct
      field :autonomy,  type: :enum, values: %i[propose_only full], default: :propose_only
      field :connected, type: :array
    end
    Agentkit::Setup.current = Agentkit::Setup.build(
      objective: :growth,
      icp: { sectors: %w[saas], geos: %w[latam], company_size: (50..200) },
      connected: %i[contacts_provider]
    )

    executed = self.class.executed = []
    stub_flow = Class.new(Agentkit::Flow) do
      def self.name = "ImportContactsFlow"
      step(:import) { executed << :ran; "12 contactos" }
    end

    Agentkit::Capability.register :import_company_contacts do |c|
      c.title "Traer contactos de una empresa"
      c.description "Importa contactos del decisor objetivo"
      c.flow stub_flow
      c.inputs company: :string
      c.preconditions { |setup, _ctx| setup.connected?(:contacts_provider) }
      c.risk :reversible
      c.cooldown 7 * 86_400
    end
  end

  class << self
    attr_accessor :executed
  end

  describe "opening the chat with no user input" do
    it "proposes actions with a why traceable to the setup" do
      turn = described_class.open(candidates: [acme, offtopic])

      expect(turn.proposals.size).to eq(1)
      proposal = turn.proposals.first
      expect(proposal.headline).to include("Acme")
      expect(proposal.why.join(" ")).to include("ICP")
      expect(turn.message).to include("Según tu setup")
    end

    it "refuses to surface a proposal with no why" do
      Agentkit.config.chat.require_why = true
      Agentkit::Setup.current = Agentkit::Setup.build(objective: :growth, connected: %i[contacts_provider])

      turn = described_class.open(candidates: [offtopic])
      expect(turn.proposals).to be_empty
    end

    it "hides capabilities whose preconditions do not hold" do
      Agentkit::Setup.current = Agentkit::Setup.build(objective: :growth, connected: [])

      turn = described_class.open(candidates: [acme])
      expect(turn.proposals).to be_empty
    end

    it "respects the proposal budget" do
      Agentkit.config.chat.max_proposals = 1
      companies = (1..5).map { |i| AgentkitSpecHelpers::Company.new(i, "Co#{i}", "saas", "latam", 100) }

      turn = described_class.open(candidates: companies)
      expect(turn.proposals.size).to eq(1)
    end
  end

  describe "accepting a proposal" do
    it "executes the capability's flow through HITL, not free text" do
      turn = described_class.open(candidates: [acme])
      Agentkit::Proposals.accept!(turn.proposals.first.id, actor: "human:1")

      expect(self.class.executed).to eq([:ran])
      expect(Agentkit::HITL.ledger.entries.last.decision).to eq("accepted")
      expect(emitted("proposal.accepted")).not_to be_empty
    end

    it "records an edit distance when the human modifies the inputs" do
      turn = described_class.open(candidates: [acme])
      Agentkit::Proposals.accept!(turn.proposals.first.id, inputs: { company: 99 }, actor: "human:1")

      entry = Agentkit::HITL.ledger.entries.last
      expect(entry.decision).to eq("edited")
      expect(entry.edit_distance).to be > 0
    end
  end

  describe "dismissing a proposal" do
    it "requires a taxonomy code and suppresses the pair after repeated rejections" do
      Agentkit.config.chat.suppress_after_rejections = 1
      Agentkit.config.chat.cooldown = nil

      turn = described_class.open(candidates: [acme])
      Agentkit::Proposals.dismiss!(turn.proposals.first.id, code: :wrong_target, actor: "human:1")

      again = described_class.open(candidates: [acme])
      expect(again.proposals).to be_empty
    end
  end

  describe "imperative orders" do
    it "turns an order into a confirmable proposal instead of executing it" do
      turn = described_class.say("traeme los contactos de una empresa")

      expect(turn.proposals.size).to eq(1)
      expect(turn.proposals.first.why).to include("lo pediste explícitamente")
      expect(self.class.executed).to be_empty  # nothing ran yet
      expect(turn.message).to include("Confirmá")
    end

    it "records a capability gap when nothing covers the intent" do
      turn = described_class.say("mandá un cohete a la luna")

      expect(turn.proposals).to be_empty
      expect(turn.state[:capability_gap]).to be(true)
      expect(Agentkit::Proposals.gaps.size).to eq(1)
      expect(emitted("proposal.capability_gap")).not_to be_empty
    end
  end

  describe "setup evolution" do
    it "suggests reviewing the ICP when wrong_target dominates rejections" do
      5.times do
        s = Agentkit::HITL.suggest!(type: "t", title: "t", source_agent: "SalesAgent")
        Agentkit::HITL.reject(s.id, actor: "human:1", code: :wrong_target)
      end

      adjustments = Agentkit::Setup.current.suggest_adjustments(Agentkit::HITL.ledger)
      expect(adjustments.map { |a| a[:field] }).to include("icp.sectors")
    end
  end
end

RSpec.describe Agentkit::Cognition do
  describe "summarizer" do
    it "summarizes on demand and caches by content" do
      fake_llm.respond_with("- punto uno\n- punto dos")

      text = described_class.run(:summarizer, source: ["texto largo sobre pagos"], strategy: :stuff)
      calls_after_first = llm_calls

      described_class.run(:summarizer, source: ["texto largo sobre pagos"], strategy: :stuff)

      expect(text).to include("punto uno")
      expect(llm_calls).to eq(calls_after_first) # second call served from cache
    end

    it "reduces in a tree for large sources" do
      fake_llm.respond_with(*Array.new(20) { |i| "resumen parcial #{i}" })
      chunks = Array.new(6) { |i| "fragmento #{i} " * 400 }

      described_class.run(:summarizer, source: chunks, strategy: :map_reduce,
                                       budget: { input_tokens: 500 })

      trace = described_class.traces.last
      expect(trace.phases.map { |p| p[:name] }).to include("map", "reduce")
    end

    it "works with no LLM at all in extractive mode" do
      before_calls = llm_calls

      text = described_class.run(:summarizer, strategy: :extractive, persist: false,
                                              source: ["Acme paga tarde. Sunrise renovó. Acme paga tarde otra vez."])

      expect(text).to include("Acme")
      expect(llm_calls).to eq(before_calls)
    end
  end

  describe "dreaming on demand" do
    before do
      Agentkit.config.memory.dreaming.min_recalls = 0
      Agentkit.config.memory.embedding.policy = :immediate
      6.times { |i| Agentkit::Memory.store("Acme pagó la factura #{i} con retraso", tags: %w[acme]) }
    end

    it "returns the plan without writing anything in dry_run" do
      trace = described_class.run(:dreaming, dry_run: true, threshold: 0.9, min_cluster: 2)

      expect(trace.status).to eq("dry_run")
      expect(trace.meta[:plan]).to be_an(Array)
      expect(Agentkit::Memory.all(types: ["insight"])).to be_empty
    end

    it "consolidates non-destructively so it can be rolled back" do
      fake_llm.respond_with("Acme es un pagador crónicamente tardío.")

      described_class.run(:dreaming, threshold: 0.9, min_cluster: 2)

      insight = Agentkit::Memory.all(types: ["insight"]).first
      sources = Agentkit::Memory.all.select { |m| m.superseded_by_id == insight.id }
      expect(insight).not_to be_nil
      expect(sources).not_to be_empty
      expect(sources.first.status).to eq("superseded")

      restored = Agentkit::Memory.rollback_supersede!(insight.id)
      expect(restored).to eq(sources.size)
    end

    it "clusters lexically with zero embeddings when configured to" do
      Agentkit.config.memory.embedding.policy = :never
      before_calls = embedding_calls
      fake_llm.respond_with("Insight sin embeddings.")

      trace = described_class.run(:dreaming, strategy: :lexical, threshold: 0.6, min_cluster: 2)

      expect(embedding_calls).to eq(before_calls)
      expect(trace.meta[:clusters]).to be >= 1
    end
  end

  describe "imagination" do
    before do
      Agentkit.config.memory.embedding.policy = :immediate
      Agentkit::Memory.store("El SRE reportó latencia alta los martes", tags: %w[sre])
      Agentkit::Memory.store("Fraude detectó picos de chargeback en marzo", tags: %w[fraude])
      Agentkit::Memory.store("Soporte recibe quejas de checkout lento", tags: %w[soporte])
      Agentkit::Memory.store("Ventas cerró tres cuentas enterprise en LATAM", tags: %w[ventas])
    end

    def script_pipeline(innovation: 0.9, relevance: 0.8, confidence: 0.8)
      fake_llm.respond_with(
        { ideas: [{ concept: "checkout adaptativo por región",
                    description: "un checkout que cambia según latencia observada",
                    originality: 0.9 }] },
        { practical_application: "Ruteo dinámico del checkout según latencia por región",
          innovation_score: innovation, relevance_score: relevance, confidence: confidence }
      )
    end

    it "stores scenarios behind the ontological firewall" do
      script_pipeline

      described_class.run(:imagination, tags: %w[exploración])

      imagined = Agentkit::Memory.all(ontological: %w[imagined])
      expect(imagined.size).to eq(1)
      expect(imagined.first.ontological_type).to eq("imagined")

      # A normal recall must never return an imagined scenario, only real facts.
      plain = Agentkit::Memory.recall("checkout adaptativo", mode: :keyword)
      expect(plain.map(&:ontological_type).uniq).to eq(["real"])

      opted_in = Agentkit::Memory.recall("checkout adaptativo", mode: :keyword, include: :imagined)
      expect(opted_in.map(&:ontological_type)).to include("imagined")
    end

    it "drops scenarios that fail the final gate" do
      script_pipeline(innovation: 0.1, relevance: 0.1, confidence: 0.1)

      described_class.run(:imagination)

      expect(Agentkit::Memory.all(ontological: %w[imagined])).to be_empty
      expect(described_class.traces.last.phases.map { |p| p[:name] }).to include("verification")
    end

    it "marks every derived suggestion as hypothetical" do
      script_pipeline

      described_class.run(:imagination, output: { suggestion: true })

      suggestion = Agentkit::HITL.pending.first
      expect(suggestion.payload["ontological_type"]).to eq("imagined")
      expect(suggestion.description).to include("ESCENARIO HIPOTÉTICO")
    end

    it "records a full XAI trace of the three phases" do
      script_pipeline

      trace = described_class.run(:imagination)
      names = described_class.traces.last.phases.map { |p| p[:name] }

      expect(names).to include("divergent_extraction", "incubation", "practicality_gate", "verification")
    end
  end
end
