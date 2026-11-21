# frozen_string_literal: true
require "spec_helper"

RSpec.describe Agentkit::AgentTool do
  def proposal(id, name, arguments = {})
    { id: id, name: name, arguments: arguments }
  end

  it "shares the parent's budget and principal while inheriting its deny boundary" do
    captured = []
    child = Class.new(Agentkit::Agent) do
      define_method(:domain_context) { captured << agent_context; "Inspect accounts" }
    end
    skill = Agentkit::Skill.define(:finance) do |s|
      s.prompt("Inspect the account")
      s.tool(:balance) { raise "must remain unavailable" }
    end
    child.uses_skills(skill.name)
    parent = Class.new(Agentkit::Agent)
    parent.allow_tools(:delegate)
    delegate = described_class.new(name: :delegate, agent: child, description: "Inspect account")
    context = Agentkit::Context.new(tenant_key: "acme", principal: "human:1")
    turns = [
      { tool_calls: [proposal("parent", "delegate", prompt: "inspect")] },
      { tool_calls: [proposal("load", "load_skill", name: "finance")] },
      { tool_calls: [proposal("denied", "balance")] },
      { content: "No balance access" },
      { content: "Child cannot access balance" }
    ].map { |turn| turn.merge(input_tokens: 10, output_tokens: 5) }
    fake_llm.respond_with_turns(*turns)
    result = parent.new(context: context).run_loop("inspect", tools: [delegate], eager_tools: ["delegate"])
    expect(result).to be_answered
    expect(result.usage.calls).to eq(5)
    expect(result.usage.total_tokens).to eq(75)
    expect(result.execution_metrics).to include(
      "direct_model_calls" => 2, "nested_model_calls" => 3,
      "direct_input_tokens" => 20, "direct_output_tokens" => 10,
      "subtree_model_calls" => 5, "subtree_input_tokens" => 50,
      "subtree_output_tokens" => 25
    )
    expect(captured.first.tenant_key).to eq("acme")
    expect(captured.first.principal).to eq("human:1")
    expect(captured.first.to_h).not_to have_key(:loop_state)
    tool_message = fake_llm.turn_calls.last.messages.find { |message| message["role"] == "tool" }
    child_result = JSON.parse(tool_message["content"]).fetch("result")
    expect(child_result["usage"]["calls"]).to eq(3)
    expect(child_result["status"]).to eq("answered")
    expect(child_result["answer"]).to eq("No balance access")

    turns = emitted("llm.turn")
    expect(turns.count { |event| event.dims[:loop_role] == "root" }).to eq(2)
    expect(turns.count { |event| event.dims[:loop_role] == "delegate" }).to eq(3)
    expect(turns.select { |event| event.dims[:loop_role] == "delegate" }
                .map { |event| event.dims[:delegation_depth] }).to all(eq(1))
    delegation = emitted("agent_tool.completed").last
    expect(delegation.dims).to include(tool: "delegate", status: "answered", delegation_depth: 1)
    expect(delegation.measures).to include(turns: 3, input_tokens: 30, output_tokens: 15,
                                            direct_model_calls: 3, nested_model_calls: 0,
                                            direct_input_tokens: 30, subtree_input_tokens: 30,
                                            limit_exhausted: false)
    expect(delegation.measures[:context_peak_bytes]).to be > 0
    expect(delegation.to_h.to_s).not_to include("inspect", "No balance access")
  end

  it "stops recursive delegation at the configured depth" do
    Agentkit.config.agent_loop.max_delegation_depth = 1
    child = Class.new(Agentkit::Agent)
    recursive = described_class.new(name: :delegate, agent: child, description: "delegate")
    skill = Agentkit::Skill.define(:delegation) do |s|
      s.description("Delegate work")
      s.tools[:delegate] = recursive
    end
    child.uses_skills(skill.name)
    fake_llm.respond_with_turns(
      { tool_calls: [proposal("parent", "delegate", prompt: "child")] },
      { tool_calls: [proposal("load", "load_skill", name: "delegation")] },
      { tool_calls: [proposal("recurse", "delegate", prompt: "again")] },
      { content: "depth stopped" }, { content: "done" }
    )
    result = Agentkit::Agent.new.run_loop("x", tools: [recursive], eager_tools: ["delegate"])
    expect(result).to be_answered
    child_messages = fake_llm.turn_calls[3].messages.select { |message| message["role"] == "tool" }
    expect(JSON.parse(child_messages.last["content"]).dig("error", "code")).to eq("Agentkit::AgentLoopLimitExceeded")
    expect(fake_llm.turn_calls.size).to eq(5)
  end
end
