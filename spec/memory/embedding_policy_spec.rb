# frozen_string_literal: true

# The ten acceptance criteria from MEMORY_POLICY.md §11.
#
# Every one of these targets a concrete cost problem observed in the v0.1
# projects: unconditional embedding per memory, vectors bought for rows that
# dreaming then archived, an un-cached query embedding on every recall, and an
# all-or-nothing kill switch that also destroyed the audit trail.
RSpec.describe "Memory embedding policy" do
  def store_many(n, type: "observation", prefix: "obs")
    (1..n).map { |i| Agentkit::Memory.store("#{prefix} number #{i} about payments", type: type) }
  end

  describe "1. policy :never issues no provider calls" do
    it "writes the row but never embeds" do
      Agentkit.config.memory.embedding.policy = :never

      record = Agentkit::Memory.store("something worth auditing")

      expect(record).not_to be_nil
      expect(record.embedding_status).to eq("skipped")
      expect(embedding_calls).to eq(0)
    end
  end

  describe "2. :on_promotion embeds insights, not raw observations" do
    it "embeds only what gets promoted" do
      Agentkit.config.memory.embedding.policy = :on_promotion

      observations = store_many(20)
      Agentkit::Memory.flush_embeddings!

      expect(embedding_calls).to eq(0)
      expect(observations.map(&:embedding_status).uniq).to eq(["none"])

      3.times { |i| Agentkit::Memory.store("consolidated insight #{i}", type: "insight") }
      Agentkit::Memory.flush_embeddings!

      expect(embedding_calls).to eq(3)
    end

    it "batches the whole flush into as few provider calls as possible" do
      Agentkit.config.memory.embedding.policy = :batched
      Agentkit.config.memory.embedding.batch_size = 100

      store_many(12)
      Agentkit::Memory.flush_embeddings!

      expect(embedding_calls).to eq(12)         # 12 texts …
      expect(fake_llm.embed_calls.size).to eq(1) # … in one request
    end
  end

  describe "3. keyword mode retrieves with zero API calls" do
    it "returns relevant rows without embedding anything" do
      Agentkit.config.memory.level = :keyword
      Agentkit::Memory.store("Acme pays invoices late every quarter", tags: %w[payment])
      Agentkit::Memory.store("Sunrise Ltd renewed the annual contract", tags: %w[contract])

      results = Agentkit::Memory.recall("invoices late", mode: :keyword)

      expect(results.size).to eq(1)
      expect(results.first.content).to include("Acme")
      expect(embedding_calls).to eq(0)
    end

    it "still stores rows at :log level so the audit trail survives" do
      Agentkit.config.memory.level = :log
      record = Agentkit::Memory.store("diagnosis for consumer 42")

      expect(record).not_to be_nil
      expect(Agentkit::Memory.all.size).to eq(1)
      expect(Agentkit::Memory.recall("diagnosis")).to be_empty
      expect(embedding_calls).to eq(0)
    end
  end

  describe "4. identical content is embedded once" do
    it "reuses the vector of an exact duplicate" do
      Agentkit.config.memory.embedding.policy = :immediate
      Agentkit.config.memory.embedding.dedupe = true

      first  = Agentkit::Memory.store("consumer analysed, winter palette")
      second = Agentkit::Memory.store("consumer analysed, winter palette")

      expect(embedding_calls).to eq(1)
      expect(second.embedding).to eq(first.embedding)
      expect(second.duplicate_of_id).to eq(first.id)
    end
  end

  describe "5. repeated queries embed once" do
    it "caches the query vector" do
      Agentkit.config.memory.level = :semantic
      Agentkit.config.memory.embedding.policy = :immediate
      Agentkit::Memory.store("Acme pays late", type: "insight")
      before = embedding_calls

      10.times { Agentkit::Memory.recall("who pays late?") }

      expect(embedding_calls - before).to eq(1)
    end

    it "normalises the query so trivial variants share the cache" do
      Agentkit.config.memory.level = :semantic
      Agentkit::Memory.store("Acme pays late", type: "insight")
      before = embedding_calls

      Agentkit::Memory.recall("Who Pays  Late?")
      Agentkit::Memory.recall("who pays late?")

      expect(embedding_calls - before).to eq(1)
    end
  end

  describe "6. exceeding the budget degrades instead of raising" do
    it "keeps answering in keyword mode and records the degradation" do
      Agentkit.config.memory.embedding.policy = :immediate
      Agentkit.config.memory.budget.embeddings_per_day = { tenant: 2 }
      Agentkit.config.memory.budget.on_exceeded = :degrade

      expect { store_many(5) }.not_to raise_error

      expect(emitted("memory.budget_exceeded")).not_to be_empty
      expect(Agentkit::Memory.recall("payments", mode: :keyword)).not_to be_empty
    end

    it "raises only when explicitly configured to" do
      Agentkit.config.memory.embedding.policy = :immediate
      Agentkit.config.memory.budget.embeddings_per_day = { tenant: 1 }
      Agentkit.config.memory.budget.on_exceeded = :raise

      Agentkit::Memory.store("first one is fine")
      expect { store_many(3) }.to raise_error(Agentkit::BudgetExceeded)
    end
  end

  describe "7. archiving frees the vector" do
    it "drops the embedding but keeps the row" do
      Agentkit.config.memory.embedding.policy = :immediate
      old = Agentkit::Memory.store("superseded observation")
      insight = Agentkit::Memory.store("the insight", type: "insight")
      Agentkit::Memory.supersede!([old], by: insight)
      Agentkit::Memory.store_backend.update(old.id, updated_at: Time.now - 30 * 86_400)

      collected = Agentkit::Memory.gc!

      expect(collected).to eq(1)
      expect(Agentkit::Memory.find(old.id)).not_to be_nil
      expect(Agentkit::Memory.find(old.id).embedding).to be_nil
    end
  end

  describe "8. the estimator predicts the bill before you turn it on" do
    it "reports what each policy would spend" do
      Agentkit.config.memory.embedding.policy = :never
      store_many(18)
      3.times { |i| Agentkit::Memory.store("insight #{i}", type: "insight") }

      estimate = Agentkit::Memory.estimate_embedding_cost(policy: :on_promotion)

      expect(estimate[:memories]).to eq(21)
      expect(estimate[:would_embed]).to eq(3)
      expect(estimate[:vs_immediate][:would_embed]).to eq(21)
      expect(estimate[:usd]).to be < estimate[:vs_immediate][:usd]
    end
  end

  describe "9. an agent declares its policy without overriding memorize!" do
    it "honours the per-agent override" do
      Agentkit.config.memory.embedding.policy = :immediate

      quiet_agent = Class.new(Agentkit::Agent) do
        memory_policy level: :log, embedding: :never
        def self.name = "QuietAgent"
        def call(text) = memorize!(text)
      end

      record = quiet_agent.new.call("skin diagnosis for consumer 7")

      expect(record.embedding_status).to eq("skipped")
      expect(embedding_calls).to eq(0)
    end
  end

  describe "10. lowering the level degrades recall, it does not break agents" do
    it "answers in keyword mode when semantics are unavailable" do
      Agentkit.config.memory.level = :semantic
      Agentkit.config.memory.embedding.policy = :immediate
      Agentkit::Memory.store("Acme pays late", type: "insight")

      Agentkit.config.memory.level = :keyword
      expect { Agentkit::Memory.recall("late payers", mode: :semantic) }.not_to raise_error

      events = emitted("memory.recall")
      expect(events.last.dims[:mode]).to eq(:keyword)
      expect(events.last.dims[:degraded]).to be(true)
    end
  end

  describe "four levels of configuration" do
    it "lets a call override the agent, the tenant and the global policy" do
      Agentkit.config.memory.embedding.policy = :never

      forced = Agentkit::Memory.store("this one matters", embed: :now)

      expect(forced.embedding_status).to eq("embedded")
      expect(embedding_calls).to eq(1)
    end

    it "applies per-tenant overrides without touching the global config" do
      Agentkit.config.memory.level = :semantic
      Agentkit.config.memory.per_tenant = lambda { |tenant|
        tenant.plan == "free" ? { level: :keyword, embedding: { policy: :never } } : {}
      }

      free = AgentkitSpecHelpers::Account.new(1, "Free Co", "free")
      paid = AgentkitSpecHelpers::Account.new(2, "Paid Co", "pro")

      with_context(account: free) do
        Agentkit::Memory.store("free tenant memory")
      end
      expect(embedding_calls).to eq(0)

      Agentkit.config.memory.embedding.policy = :immediate
      with_context(account: paid) do
        Agentkit::Memory.store("paid tenant memory")
      end
      expect(embedding_calls).to eq(1)
      expect(Agentkit.config.memory.level).to eq(:semantic)
    end
  end

  describe "dreaming does not pre-pay for vectors it will supersede" do
    it "embeds the window once at consolidation time, not per observation" do
      Agentkit.config.memory.embedding.policy = :on_promotion
      Agentkit.config.memory.dreaming.clustering = :batch_embed
      Agentkit.config.memory.dreaming.min_recalls = 0
      fake_llm.respond_with("Acme is a chronic late payer.")

      6.times { |i| Agentkit::Memory.store("Acme paid invoice #{i} late", tags: %w[acme]) }
      expect(embedding_calls).to eq(0)

      trace = Agentkit::Cognition.run(:dreaming, min_cluster: 2, threshold: 0.9)

      expect(trace.phases.map { |p| p[:name] }).to include("batch_embed")
      # The whole window goes out in ONE request instead of six scattered ones.
      expect(fake_llm.embed_calls.first[:texts].size).to eq(6)
      expect(trace.meta[:insights]).to be >= 1
    end
  end
end
