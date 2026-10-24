# frozen_string_literal: true
require "spec_helper"

RSpec.describe Agentkit::ExecutionBudget do
  it "attributes nested usage to its subtree exactly once" do
    root = described_class.new
    child = root.child
    grandchild = child.child
    root.charge_usage!(Agentkit::Usage.new(input_tokens: 10))
    child.charge_usage!(Agentkit::Usage.new(input_tokens: 20))
    grandchild.charge_usage!(Agentkit::Usage.new(input_tokens: 30))
    expect(root.usage.total_tokens).to eq(60)
    expect(child.usage.total_tokens).to eq(50)
    expect(grandchild.usage.total_tokens).to eq(30)
    expect(root.usage.calls).to eq(3)
  end

  it "admits only the shared number of concurrent model requests" do
    root = described_class.new(max_turns: 3)
    profile = Agentkit::ModelRouter.profile_for(:default)
    results = 12.times.map do
      Thread.new do
        root.child.admit_model!(profile)
        :admitted
      rescue Agentkit::BudgetExceeded
        :blocked
      end
    end.map(&:value)
    expect(results.count(:admitted)).to eq(3)
    expect(results.count(:blocked)).to eq(9)
  end

  it "rejects unpriced models before the provider when a cost limit is configured" do
    budget = described_class.new
    Agentkit::ModelRouter.register(:unpriced, model: "unknown-price")
    result = Agentkit::Agent.new.run_loop("x", model: :unpriced, budget: budget)
    expect(result.stop_reason).to eq("error")
    expect(result.error_code).to eq("Agentkit::ConfigurationError")
    expect(fake_llm.turn_calls).to be_empty
    expect(result.budget[:unpriced_models]).to eq(["unknown-price"])
  end

  it "records unpriced models explicitly when the cost limit is disabled" do
    budget = described_class.new(max_cost_usd: nil)
    Agentkit::ModelRouter.register(:unpriced, model: "unknown-price")
    result = Agentkit::Agent.new.run_loop("x", model: :unpriced, budget: budget)
    expect(result).to be_answered
    expect(result.budget[:unpriced_models]).to eq(["unknown-price"])
  end

  it "blocks tool execution after the measured cost exceeds the remaining budget" do
    called = false
    budget = described_class.new(max_cost_usd: 0.000001)
    lookup = Agentkit::ToolContract.new(name: :lookup, callable: -> { called = true })
    fake_llm.respond_with_turns(input_tokens: 100, output_tokens: 10,
      tool_calls: [{ id: "read", name: "lookup", arguments: {} }])
    result = Agentkit::Agent.new.run_loop("x", budget: budget, tools: [lookup], eager_tools: ["lookup"])
    expect(result.stop_reason).to eq("budget_exhausted")
    expect(result.usage.cost_usd).to be > 0.000001
    expect(called).to be(false)
  end

  it "rejects legacy auto-executing SDK tool loops inside a shared budget" do
    context = Agentkit::Context.new(budget: described_class.new)
    lookup = Agentkit::ToolContract.new(name: :lookup, callable: -> { 42 })
    Agentkit.with_context(context) do
      expect { Agentkit::LLM.complete("x", tools: [lookup]) }
        .to raise_error(Agentkit::ConfigurationError, /opaque/)
    end
    expect(fake_llm.calls).to be_empty
  end

  it "marks failed provider requests as unmeasured rather than claiming a known zero cost" do
    fake_llm.respond_with_turns(StandardError.new("PRIVATE PROVIDER FAILURE"))
    result = Agentkit::Agent.new.run_loop("x")
    expect(result.stop_reason).to eq("error")
    expect(result.budget[:admitted_calls]).to eq(1)
    expect(result.budget[:unmeasured_calls]).to eq(1)
    expect(result.to_h.to_s).not_to include("PRIVATE PROVIDER FAILURE")
  end

  it "keeps each loop's usage local when a caller reuses a shared request budget" do
    shared = described_class.new
    fake_llm.respond_with_turns(
      { content: "first", input_tokens: 10, output_tokens: 5 },
      { content: "second", input_tokens: 20, output_tokens: 5 }
    )
    first = Agentkit::Agent.new.run_loop("first", budget: shared)
    second = Agentkit::Agent.new.run_loop("second", budget: shared)
    expect(first.usage.total_tokens).to eq(15)
    expect(second.usage.total_tokens).to eq(25)
    expect(second.usage.calls).to eq(1)
    expect(shared.usage.total_tokens).to eq(40)
    expect(shared.usage.calls).to eq(2)
  end

  it "does not let a nested loop replace the inherited budget" do
    inherited = described_class.new(max_turns: 1)
    agent = Agentkit::Agent.new(context: Agentkit::Context.new(budget: inherited))
    expect { agent.run_loop("x", budget: described_class.new(max_turns: 100)) }
      .to raise_error(Agentkit::ConfigurationError, /cannot be replaced/)
  end

  it "charges schema-invalid legacy responses even when no answer is returned" do
    schema = Agentkit::LLM::Schema.define { string :name, required: true }
    budget = described_class.new
    Agentkit.config.llm.schema_retries = 0
    fake_llm.respond_with("not json", "still invalid")
    Agentkit.with_context(Agentkit::Context.new(budget: budget)) do
      expect { Agentkit::LLM.complete("x", schema: schema) }.to raise_error(Agentkit::SchemaViolation)
    end
    expect(budget.usage.calls).to eq(fake_llm.calls.size)
    expect(budget.usage.calls).to be > 0
  end
end
