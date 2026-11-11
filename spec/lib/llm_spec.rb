# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::LLM do
  describe "structured output" do
    let(:schema) do
      Agentkit::LLM::Schema.define do
        string :concept, required: true, min_length: 5
        number :score,   required: true, min: 0, max: 1
        array  :tags
      end
    end
    let(:charges) { [] }
    let(:budget) do
      double("budget").tap do |ledger|
        allow(ledger).to receive(:charge) { |resource, cost| charges << [resource, cost] }
      end
    end

    it "extracts JSON out of a fenced markdown block" do
      fake_llm.respond_with(<<~REPLY)
        Sure! Here you go:
        ```json
        {"concept": "late payment risk", "score": 0.8, "tags": ["finance"]}
        ```
      REPLY

      response = described_class.complete("analyse", schema: schema)

      expect(response.parsed[:concept]).to eq("late payment risk")
      expect(response.parsed[:score]).to eq(0.8)
    end

    it "handles nested braces without mis-slicing" do
      fake_llm.respond_with('prefix {"concept": "a {tricky} one", "score": 0.5} trailing prose')

      response = described_class.complete("x", schema: schema)
      expect(response.parsed[:concept]).to eq("a {tricky} one")
    end

    it "coerces stringified numbers instead of re-asking" do
      fake_llm.respond_with('{"concept": "coercion works", "score": "0.42"}')

      response = described_class.complete("x", schema: schema)
      expect(response.parsed[:score]).to eq(0.42)
      expect(llm_calls).to eq(1)
    end

    it "repairs on the same profile and accounts for each provider response once" do
      Agentkit::ModelRouter.register(:structured, model: "structured-model", provider: :openai_compatible,
                                                api_base: "https://example.test/v1", api_key: "test-key",
                                                price_in: 2.0, price_out: 10.0)
      fake_llm.respond_with(
        '{"concept": "x", "score": 5}',                       # too short + out of range
        '{"concept": "valid concept", "score": 0.7}'
      )

      execution_budget = Agentkit::ExecutionBudget.new(external: budget)
      response = with_context(budget: execution_budget) do
        described_class.complete("x", model: :structured, schema: schema, system: "Analyse the text",
                                      prompt_id: "extract", prompt_version: 3,
                                      experiment_id: "test-experiment", experiment_arm: "variant")
      end

      expect(response.parsed[:concept]).to eq("valid concept")
      expect(response.model).to eq("structured-model")
      expect(response.profile).to eq(:structured)
      expect(llm_calls).to eq(2)
      original, repair = fake_llm.calls
      expect(repair).to have_attributes(model: original.model, system: original.system, temperature: 0.0,
                                         api_base: original.api_base, api_key: original.api_key)
      expect(repair.prompt).to include("shorter than", "above 1")

      events = emitted("llm.call")
      expect(events.map { |event| event.dims[:status] }).to eq(%w[schema_violation ok])
      events.each do |event|
        expect(event.dims).to include(model: "structured-model", profile: :structured,
                                      provider: :openai_compatible, prompt_id: "extract", prompt_version: 3,
                                      experiment_id: "test-experiment", experiment_arm: "variant")
        usage = event.measures
        expect(usage[:cost_usd]).to eq((usage[:input_tokens] * 2.0 + usage[:output_tokens] * 10.0) / 1_000_000.0)
      end
      expect(charges).to eq(events.map { |event| [:llm_usd, event.measures[:cost_usd]] })
      expect(response.usage).to have_attributes(calls: 2, cost_usd: charges.sum(&:last),
                                               input_tokens: events.sum { |event| event.measures[:input_tokens] },
                                               output_tokens: events.sum { |event| event.measures[:output_tokens] })
      expect(execution_budget.snapshot[:admitted_calls]).to eq(2)
      expect(execution_budget.usage).to have_attributes(calls: 2, total_tokens: response.usage.total_tokens,
                                                        cost_usd: response.usage.cost_usd)
    end

    it "charges and records both responses when repair still violates the schema" do
      fake_llm.respond_with("not json at all", "still not json")

      expect do
        with_context(budget: budget) { described_class.complete("x", schema: schema) }
      end.to raise_error(Agentkit::SchemaViolation, /failed schema/) { |error| expect(error.raw).to eq("still not json") }

      expect(llm_calls).to eq(2)
      events = emitted("llm.call")
      expect(events.map { |event| event.dims[:status] }).to eq(%w[schema_violation schema_violation])
      expect(charges).to eq(events.map { |event| [:llm_usd, event.measures[:cost_usd]] })
      expect(charges.map(&:last)).to all(be > 0)
    end

    it "records usage when an invalid response exhausts the budget before repair" do
      execution_budget = Agentkit::ExecutionBudget.new(max_tokens: 1)
      fake_llm.respond_with("not json at all")

      expect do
        with_context(budget: execution_budget) { described_class.complete("x", schema: schema) }
      end.to raise_error(Agentkit::BudgetExceeded)

      expect(llm_calls).to eq(1)
      events = emitted("llm.call")
      expect(events.size).to eq(1)
      expect(events.first.dims).to include(status: "error", error_class: "Agentkit::BudgetExceeded")
      expect(events.first.measures[:cost_usd]).to eq(execution_budget.usage.cost_usd)
      expect(execution_budget.usage.calls).to eq(1)
    end

    it "admits the repair as a separate request under the execution budget" do
      execution_budget = Agentkit::ExecutionBudget.new(max_turns: 1)
      fake_llm.respond_with("not json at all")

      expect do
        with_context(budget: execution_budget) { described_class.complete("x", schema: schema) }
      end.to raise_error(Agentkit::BudgetExceeded)

      expect(llm_calls).to eq(1)
      expect(emitted("llm.call").map { |event| event.dims[:status] }).to eq(["schema_violation"])
      expect(execution_budget.usage.calls).to eq(1)
    end

    # `object` accepted a block from the start; `array` did not, silently —
    # calling it with one just dropped the block and left the item schema nil.
    # A caller reaching for "array of objects" (the shape a list of steps or
    # moves naturally takes) had no way to say so.
    describe "array of objects" do
      let(:schema_anidado) do
        Agentkit::LLM::Schema.define do
          string :titulo, required: true
          array :pasos, required: true do
            string :accion, required: true
            string :motivo
          end
        end
      end

      it "parses and coerces each item against the nested schema" do
        fake_llm.respond_with(
          '{"titulo": "plan", "pasos": [{"accion": "llamar", "motivo": "urgente"}, {"accion": "escribir"}]}'
        )

        response = described_class.complete("x", schema: schema_anidado)

        expect(response.parsed[:pasos].size).to eq(2)
        expect(response.parsed[:pasos].first).to eq(accion: "llamar", motivo: "urgente")
        expect(response.parsed[:pasos].last[:accion]).to eq("escribir")
      end

      it "validates each item and re-asks pointing at which one failed" do
        fake_llm.respond_with(
          '{"titulo": "plan", "pasos": [{"accion": "ok"}, {"motivo": "sin accion"}]}',
          '{"titulo": "plan", "pasos": [{"accion": "ok"}, {"accion": "arreglado"}]}'
        )

        response = described_class.complete("x", schema: schema_anidado)

        expect(llm_calls).to eq(2)
        expect(fake_llm.calls.last.prompt).to include("pasos[1]", "accion")
        expect(response.parsed[:pasos].last[:accion]).to eq("arreglado")
      end
    end
  end

  describe "retries and fallback" do
    it "retries a transient error with backoff" do
      Agentkit.config.llm.backoff_base = 0
      fake_llm.fail_on(times: 2)
      fake_llm.respond_with("recovered")

      response = described_class.complete("x")

      expect(response.content).to eq("recovered")
      expect(response.attempts).to eq(3)
    end

    it "falls back to the next profile on a permanent error" do
      Agentkit.config.llm.profiles[:complex] = Agentkit::ModelProfile.new(
        model: "broken-model", fallback: :default
      )
      fake_llm.fail_on(times: 5, model: "broken-model", error: Agentkit::PermanentError)
      fake_llm.respond_with("from the fallback")

      response = described_class.complete("x", model: :complex)

      expect(response.content).to eq("from the fallback")
      expect(response).to be_fallback_used
    end
  end

  describe "cost accounting" do
    it "prices a call and reports usage" do
      Agentkit::LLM::Pricing.register("claude-sonnet-4-6", input: 3.0, output: 15.0)
      fake_llm.respond_with("a" * 400)

      response = described_class.complete("b" * 400)

      expect(response.usage.input_tokens).to be > 0
      expect(response.usage.cost_usd).to be > 0
      expect(emitted("llm.call").last.measures[:cost_usd]).to eq(response.usage.cost_usd)
    end

    it "resolves provider-prefixed model ids against the price table" do
      expect(Agentkit::LLM::Pricing.for("anthropic/claude-sonnet-4-6")).not_to be_nil
    end
  end

  describe "circuit breaker" do
    it "opens after repeated failures and reports unpriced models" do
      Agentkit.config.llm.backoff_base = 0
      Agentkit.config.llm.breaker_threshold = 2
      Agentkit.config.llm.retries = 0
      fake_llm.fail_on(times: 10)

      2.times { described_class.complete("x") rescue nil }

      expect(described_class.circuit_open?(:ruby_llm)).to be(true)
    end
  end

  describe "the fake adapter" do
    it "produces deterministic embeddings so recall specs are reproducible" do
      a = described_class.embed(["same text"]).first
      b = described_class.embed(["same text"]).first
      c = described_class.embed(["different"]).first

      expect(a).to eq(b)
      expect(a).not_to eq(c)
    end
  end
end

RSpec.describe Agentkit::ModelRouter do
  it "passes an explicit model string through" do
    expect(described_class.resolve("qwen3.7-plus")).to eq("qwen3.7-plus")
  end

  it "raises on an unknown profile instead of silently defaulting" do
    expect { described_class.profile_for(:nonexistent) }
      .to raise_error(Agentkit::ConfigurationError, /Unknown model profile/)
  end

  it "reports models with no price so cost tracking cannot lie by omission" do
    described_class.register(:exotic, model: "some-unpriced-model")
    expect(described_class.unpriced_models).to include("some-unpriced-model")
  end
end

RSpec.describe Agentkit::Prompt do
  it "assigns a canary deterministically by bucket" do
    described_class.define(:sales, version: 1) { "v1 body" }
    described_class.define(:sales, version: 2, status: :draft) { "v2 body" }
    described_class.canary(:sales, version: 2, percent: 100)

    ctx = Agentkit::Context.new(tenant_key: "acme")
    text, version = described_class.render(:sales, ctx)

    expect(text).to eq("v2 body")
    expect(version).to eq(2)
    expect(described_class.render(:sales, ctx).last).to eq(2) # stable
  end

  it "keeps the canary out of excluded prompts" do
    described_class.define(:ops, version: 1) { "process the order" }
    described_class.define(:ops, version: 2, status: :draft) { "process the refund" }
    described_class.canary(:ops, version: 2, percent: 100,
                                 exclude_if: ->(text) { text.match?(/refund/i) })

    text, version = described_class.render(:ops, Agentkit::Context.new(tenant_key: "x"))
    expect(text).to eq("process the order")
    expect(version).to eq(1)
  end

  it "promotes and rolls back" do
    described_class.define(:x, version: 1) { "one" }
    described_class.define(:x, version: 2, status: :draft) { "two" }
    described_class.canary(:x, version: 2, percent: 50)

    described_class.promote(:x)
    expect(described_class.active_version(:x)).to eq(2)

    described_class.rollback(:x, to: 1)
    expect(described_class.active_version(:x)).to eq(1)
  end
end
