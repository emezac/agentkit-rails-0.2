# frozen_string_literal: true
require "spec_helper"
require "timeout"

RSpec.describe Agentkit::AgentLoop do
  def call_tool(id, name, arguments = {})
    { id: id, name: name, arguments: arguments }
  end

  def tool(name = :balance, **options, &block)
    Agentkit::ToolContract.new(name: name, description: "Read account balance",
      params: {}, **options, callable: block || -> { { balance: 42 } })
  end

  def run_loop(**options)
    Agentkit::Agent.new(context: @context).run_loop("private user request", **options)
  end

  def last_results
    fake_llm.turn_calls.last.messages.select { |message| message["role"] == "tool" }
      .map { |message| JSON.parse(message.fetch("content")) }
  end

  before do
    @context = Agentkit::Context.new(tenant_key: "acme", principal: "human:42")
  end

  it "loads procedures/providers once and exposes only metadata before loading" do
    renders = 0
    providers = 0
    captured = []
    skill = Agentkit::Skill.define(:finance) do |s|
      s.description("Financial account lookup")
      s.trigger("account balance")
      s.prompt { renders += 1; "SECRET PROCEDURE" }
      s.context_provider(:notes) { providers += 1; "PRIVATE CONTEXT" }
      s.tool(:balance) { captured << Agentkit::Context.current; { balance: 42 } }
    end
    fake_llm.respond_with_turns(
      { tool_calls: [call_tool("load-1", "load_skill", name: "finance")] },
      { tool_calls: [call_tool("load-2", "load_skill", name: "finance")] },
      { tool_calls: [call_tool("read", "balance")] }, { content: "42" }
    )
    outcome = run_loop(skills: [skill])
    expect(outcome).to be_answered
    expect([renders, providers, captured.size]).to eq([1, 1, 1])
    expect(outcome.loaded_skills).to eq(["finance"])
    expect(fake_llm.turn_calls.first.messages.first["content"]).to include("Financial account lookup")
    expect(fake_llm.turn_calls.first.messages.first["content"]).not_to include("SECRET PROCEDURE", "PRIVATE CONTEXT")
    expect(fake_llm.turn_calls.first.tools.map { |schema| schema["name"] }).not_to include("balance")
    expect(fake_llm.turn_calls[1].tools.map { |schema| schema["name"] }).to include("balance")
    expect(captured.first.tenant_key).to eq("acme")
    expect(captured.first.principal).to eq("human:42")
  end

  it "discovers schemas then executes in the same conversation without logging raw data" do
    lookup = tool { "PRIVATE TOOL DATA" }
    fake_llm.respond_with_turns(
      { tool_calls: [call_tool("search", "search_tools", query: "balance")] },
      { tool_calls: [call_tool("read", "balance")] }, { content: "done" }
    )
    result = run_loop(tools: [lookup])
    expect(result).to be_answered
    expect(last_results.last.dig("result")).to eq("PRIVATE TOOL DATA")
    expect(result.evidence_refs.size).to eq(1)
    expect(result.usage.calls).to eq(3)
    audit = Agentkit::Audit.entries.map(&:to_h).to_s
    expect(audit).not_to include("PRIVATE TOOL DATA", "private user request")
    expect(audit).to include("transcript_digest")
  end

  it "does not execute a known but undisclosed tool or a schema loaded in the same batch" do
    hits = 0
    lookup = tool { hits += 1; 42 }
    fake_llm.respond_with_turns(
      { tool_calls: [call_tool("search", "search_tools", query: "balance"), call_tool("early", "balance")] },
      { tool_calls: [call_tool("next", "balance")] }, { content: "done" }
    )
    result = run_loop(tools: [lookup])
    expect(result).to be_answered
    expect(hits).to eq(1)
    expect(last_results[1].dig("error", "code")).to eq("Agentkit::ToolExecutionDenied")
  end

  it "applies class deny policies to discovery and rejects explicit overrides" do
    klass = Class.new(Agentkit::Agent)
    klass.deny_tools(:balance)
    fake_llm.respond_with_turns(
      { tool_calls: [call_tool("search", "search_tools", query: "balance")] }, { content: "done" }
    )
    result = klass.new(context: @context).run_loop("x", tools: [tool])
    expect(result).to be_answered
    expect(last_results.first.dig("result", "tools")).to eq([])
  end

  it "rechecks authorization between two calls in an already offered batch" do
    allowed = true
    hits = 0
    revoke = tool(:revoke) { allowed = false; "revoked" }
    lookup = tool { hits += 1; 42 }
    fake_llm.respond_with_turns(
      { tool_calls: [call_tool("revoke", "revoke"), call_tool("read", "balance")] }, { content: "done" }
    )
    result = run_loop(tools: [revoke, lookup], eager_tools: %w[revoke balance],
      authorize: ->(contract, _) { contract.name != :balance || allowed })
    expect(result).to be_answered
    expect(hits).to eq(0)
    expect(last_results.last.dig("error", "code")).to eq("Agentkit::ToolExecutionDenied")
  end

  it "hides forbidden skills and their tools without rendering their providers" do
    touched = false
    skill = Agentkit::Skill.define(:hidden) do |s|
      s.description("PRIVATE SKILL")
      s.prompt { touched = true; "private" }
      s.tool(:balance) { touched = true; 42 }
    end
    fake_llm.respond_with_turns(
      { tool_calls: [call_tool("search", "search_tools", query: "balance")] }, { content: "done" }
    )
    result = run_loop(skills: [skill], authorize_skill: ->(*) { false })
    expect(result).to be_answered
    expect(touched).to be(false)
    expect(fake_llm.turn_calls.first.messages.first["content"]).not_to include("PRIVATE SKILL")
    expect(last_results.first.dig("result", "tools")).to eq([])
  end

  it "routes side-effecting tools to an error instead of directly executing them" do
    hits = 0
    write = tool(:write, effect: :external) { hits += 1 }
    fake_llm.respond_with_turns({ tool_calls: [call_tool("write", "write")] }, { content: "no write" })
    result = run_loop(tools: [write], eager_tools: ["write"])
    expect(result).to be_answered
    expect(hits).to eq(0)
    expect(last_results.first.dig("error", "code")).to eq("Agentkit::ToolExecutionDenied")
  end

  it "charges a response that exhausts tokens and executes none of its tools" do
    hits = 0
    budget = Agentkit::ExecutionBudget.new(max_tokens: 20)
    fake_llm.respond_with_turns(input_tokens: 20, output_tokens: 1, tool_calls: [call_tool("read", "balance")])
    result = run_loop(tools: [tool { hits += 1 }], eager_tools: ["balance"], budget: budget)
    expect(result.stop_reason).to eq("budget_exhausted")
    expect(result.usage.total_tokens).to eq(21)
    expect(hits).to eq(0)
  end

  it "stops at the shared model-call budget without another paid request" do
    budget = Agentkit::ExecutionBudget.new(max_turns: 1)
    fake_llm.respond_with_turns({ tool_calls: [call_tool("search", "search_tools", query: "balance")] },
                               { content: "should not run" })
    result = run_loop(tools: [tool], budget: budget)
    expect(result.stop_reason).to eq("budget_exhausted")
    expect(fake_llm.turn_calls.size).to eq(1)
    expect(result.budget[:admitted_calls]).to eq(1)
  end

  it "rejects overlarge batches and duplicate ids before invoking any tool" do
    hits = 0
    lookup = tool { hits += 1 }
    Agentkit.config.agent_loop.max_batch = 1
    fake_llm.respond_with_turns(tool_calls: [call_tool("a", "balance"), call_tool("b", "balance")])
    expect(run_loop(tools: [lookup], eager_tools: ["balance"]).stop_reason).to eq("batch_limit")
    Agentkit.config.agent_loop.max_batch = 8
    fake_llm.respond_with_turns(tool_calls: [call_tool("same", "balance"), call_tool("same", "balance")])
    expect(run_loop(tools: [lookup], eager_tools: ["balance"]).stop_reason).to eq("protocol_error")
    expect(hits).to eq(0)
  end

  it "withholds truncated or filtered answers even when they include tool proposals" do
    hits = 0
    fake_llm.respond_with_turns(stop_reason: "max_tokens", content: "partial",
      tool_calls: [call_tool("read", "balance")])
    result = run_loop(tools: [tool { hits += 1 }], eager_tools: ["balance"])
    expect(result.stop_reason).to eq("max_tokens")
    expect(result.content).to be_nil
    expect(hits).to eq(0)
  end

  it "withholds answers rejected twice by an independent verifier" do
    fake_llm.respond_with_turns({ content: "unsupported one" }, { content: "unsupported two" })
    result = run_loop(verifier: ->(request, context) {
      expect(request).to be_frozen
      expect(context.tenant_key).to eq("acme")
      { accepted: false, reasons: ["missing evidence"] }
    })
    expect(result.stop_reason).to eq("verification_failed")
    expect(result.content).to be_nil
    expect(fake_llm.turn_calls.size).to eq(2)
  end

  it "checks byte limits before the first provider call" do
    Agentkit.config.agent_loop.max_context_bytes = 32
    expect(run_loop.stop_reason).to eq("context_limit")
    expect(fake_llm.turn_calls).to be_empty
  end

  it "does not truncate skill procedures or mark an oversized skill as loaded" do
    Agentkit.config.agent_loop.max_skill_bytes = 100
    skill = Agentkit::Skill.define(:large) { |s| s.prompt("x" * 500) }
    fake_llm.respond_with_turns({ tool_calls: [call_tool("load", "load_skill", name: "large")] }, { content: "done" })
    result = run_loop(skills: [skill])
    expect(result.loaded_skills).to be_empty
    expect(last_results.first.dig("error", "code")).to eq("Agentkit::AgentLoopLimitExceeded")
  end

  it "does not leak tool exception text and can recover on the next turn" do
    fake_llm.respond_with_turns({ tool_calls: [call_tool("read", "balance")] }, { content: "unavailable" })
    result = run_loop(tools: [tool { raise "PRIVATE FAILURE" }], eager_tools: ["balance"])
    expect(result).to be_answered
    expect(last_results.to_s).not_to include("PRIVATE FAILURE")
    expect(Agentkit::Audit.entries.map(&:to_h).to_s).not_to include("PRIVATE FAILURE")
  end

  it "runs only explicitly parallel-safe reads concurrently and preserves result order" do
    ready, release = Queue.new, Queue.new
    first = tool(:first, metadata: { parallel_safe: true }) { ready << 1; release.pop; "one" }
    second = tool(:second, metadata: { parallel_safe: true }) { ready << 2; release.pop; "two" }
    fake_llm.respond_with_turns(
      { tool_calls: [call_tool("one", "first"), call_tool("two", "second")] }, { content: "done" })
    worker = Thread.new { run_loop(tools: [first, second], eager_tools: %w[first second]) }
    begin
      Timeout.timeout(3) { 2.times { ready.pop } }
    ensure
      2.times { release << true }
    end
    expect(worker.value).to be_answered
    expect(last_results.map { |entry| entry["result"] }).to eq(%w[one two])
  end

  it "charges legacy LLM calls and schema repairs inside tools exactly once" do
    schema = Agentkit::LLM::Schema.define { string :name, required: true }
    fake_llm.respond_with('{"wrong":1}', '{"name":"fixed"}')
    legacy = tool { Agentkit::LLM.complete("fix", schema: schema).parsed }
    fake_llm.respond_with_turns({ tool_calls: [call_tool("read", "balance")] }, { content: "done" })
    result = run_loop(tools: [legacy], eager_tools: ["balance"])
    expect(result).to be_answered
    expect(result.usage.calls).to eq(4) # two loop turns + two schema attempts
    expect(fake_llm.calls.size).to eq(4)
  end

  it "validates and repairs final structured output within the same bounded loop" do
    schema = { type: "object", properties: { answer: { type: "string" } },
               required: ["answer"], additionalProperties: false }
    fake_llm.respond_with_turns({ content: '{"wrong":42}' }, { content: '{"answer":"verified"}' })
    result = run_loop(schema: schema)
    expect(result).to be_answered
    expect(result.parsed).to eq("answer" => "verified")
    expect(result.parsed).to be_frozen
    expect(result.usage.calls).to eq(2)
  end

  it "withholds invalid structured answers after the bounded repair allowance" do
    schema = { type: "object", required: ["answer"] }
    fake_llm.respond_with_turns({ content: "{}" }, { content: "invalid JSON" })
    result = run_loop(schema: schema)
    expect(result.stop_reason).to eq("validation_failed")
    expect(result.content).to be_nil
    expect(result.parsed).to be_nil
  end

  it "is single-use so loaded context cannot leak into another request" do
    loop = described_class.new(agent: Agentkit::Agent.new(context: @context))
    expect(loop.run("first")).to be_answered
    expect { loop.run("second") }.to raise_error(Agentkit::ConfigurationError, /reused/)
  end
end
