# frozen_string_literal: true
require "spec_helper"
require "ruby_llm"
require "webmock/rspec"

RSpec.describe "Progressive loop native RubyLLM contract" do
  ENDPOINT = "https://loop-sdk.example/v1/chat/completions"

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    Agentkit.config.llm.adapter = :ruby_llm
    Agentkit::ModelRouter.register(:gateway, model: "loop-contract-model",
      api_base: "https://loop-sdk.example/v1", api_key: "test-only-key", price_in: 1, price_out: 2)
  end

  after do
    WebMock.reset!
    WebMock.disable!
  end

  def response(message, finish: "stop", cached: 0)
    JSON.generate(id: "response-1", model: "loop-contract-model",
      choices: [{ index: 0, message: message, finish_reason: finish }],
      usage: { prompt_tokens: 100, completion_tokens: 10, prompt_tokens_details: { cached_tokens: cached } })
  end

  def headers = { "Content-Type" => "application/json" }

  it "returns native tool proposals without executing the SDK's own tool loop" do
    stub = stub_request(:post, ENDPOINT).with { |request|
      body = JSON.parse(request.body)
      expect(body["tools"].first.dig("function", "parameters", "required")).to eq(["id"])
      expect(body["max_completion_tokens"]).to eq(128)
      expect(request.headers["Authorization"]).to eq("Bearer test-only-key")
      true
    }.to_return(status: 200, headers: headers, body: response({
      role: "assistant", content: nil, tool_calls: [
        { id: "native-1", type: "function", function: { name: "lookup", arguments: '{"id":42}' } }
      ]
    }, finish: "tool_calls", cached: 30))
    result = Agentkit::LLM.turn(
      model: :gateway, messages: [{ "role" => "user", "content" => "lookup" }], max_tokens: 128,
      tools: [{ "name" => "lookup", "description" => "Read an account", "input_schema" => {
        "type" => "object", "properties" => { "id" => { "type" => "integer" } },
        "required" => ["id"], "additionalProperties" => false } }]
    )
    expect(result.stop_reason).to eq("tool_calls")
    expect(result.message["tool_calls"].first["arguments"]).to eq("id" => 42)
    expect(result.usage.input_tokens).to eq(100) # cached input is still part of the token budget
    expect(stub).to have_been_requested.once
  end

  it "replays native tool ids, arguments and results in the same conversation" do
    bodies = []
    stub = stub_request(:post, ENDPOINT).with { |request| bodies << JSON.parse(request.body); true }.to_return(
      { status: 200, headers: headers, body: response({
        role: "assistant", content: nil, tool_calls: [
          { id: "native-2", type: "function", function: { name: "lookup", arguments: '{}' } }
        ]
      }, finish: "tool_calls") },
      { status: 200, headers: headers, body: response({ role: "assistant", content: "Balance 42" }) }
    )
    seen_context = nil
    lookup = Agentkit::ToolContract.new(name: :lookup, description: "Account balance", callable: -> {
      seen_context = Agentkit::Context.current
      { balance: 42 }
    })
    context = Agentkit::Context.new(tenant_key: "acme", principal: "human:1")
    result = Agentkit::Agent.new(context: context).run_loop("balance", model: :gateway,
      tools: [lookup], eager_tools: ["lookup"])
    expect(result).to be_answered
    expect(result.content).to eq("Balance 42")
    expect(result.usage.calls).to eq(2)
    expect(seen_context.tenant_key).to eq("acme")
    expect(bodies.last["messages"].map { |message| message["role"] }).to eq(%w[system user assistant tool])
    tool_message = bodies.last["messages"].last
    expect(tool_message["tool_call_id"]).to eq("native-2")
    expect(JSON.parse(tool_message["content"]).dig("result", "balance")).to eq(42)
    expect(stub).to have_been_requested.twice
  end

  it "keeps the real SDK configuration isolated between per-profile credentials" do
    original_base = RubyLLM.config.openai_api_base
    original_key = RubyLLM.config.openai_api_key
    stub_request(:post, ENDPOINT).to_return(status: 200, headers: headers,
      body: response({ role: "assistant", content: "first" }))
    other = "https://other-loop.example/v1/chat/completions"
    Agentkit::ModelRouter.register(:other_gateway, model: "another-model",
      api_base: "https://other-loop.example/v1", api_key: "other-test-key", price_in: 1, price_out: 2)
    stub_request(:post, other).with(headers: { "Authorization" => "Bearer other-test-key" })
      .to_return(status: 200, headers: headers, body: response({ role: "assistant", content: "other" }))
    messages = [{ "role" => "user", "content" => "hello" }]
    expect(Agentkit::LLM.turn(model: :gateway, messages: messages, tools: []).message["content"]).to eq("first")
    expect(Agentkit::LLM.turn(model: :other_gateway, messages: messages, tools: []).message["content"]).to eq("other")
    expect(RubyLLM.config.openai_api_base).to eq(original_base)
    expect(RubyLLM.config.openai_api_key).to eq(original_key)
  end


  it "preserves Anthropic signed and redacted blocks, tool results and cached input" do
    old_key = RubyLLM.config.anthropic_api_key
    RubyLLM.config.anthropic_api_key = "test-anthropic-key"
    native_model = RubyLLM::Model::Info.default("loop-anthropic-contract", "anthropic")
    RubyLLM.models.all << native_model
    Agentkit::LLM::Pricing.register(native_model.id, input: 3, output: 15)
    Agentkit::ModelRouter.register(:native_anthropic, model: native_model.id)
    endpoint = "https://api.anthropic.com/v1/messages"
    blocks = [
      { type: "thinking", thinking: "private reasoning", signature: "signed-block" },
      { type: "redacted_thinking", data: "redacted-signed-block" },
      { type: "tool_use", id: "anthropic-call", name: "lookup", input: {} }
    ]
    bodies = []
    stub = stub_request(:post, endpoint).with { |request| bodies << JSON.parse(request.body); true }.to_return(
      { status: 200, headers: headers, body: JSON.generate(id: "anthropic-1", type: "message",
        role: "assistant", model: native_model.id, content: blocks, stop_reason: "tool_use",
        usage: { input_tokens: 30, cache_read_input_tokens: 20, cache_creation_input_tokens: 10, output_tokens: 15 }) },
      { status: 200, headers: headers, body: JSON.generate(id: "anthropic-2", type: "message",
        role: "assistant", model: native_model.id, content: [{ type: "text", text: "42" }], stop_reason: "end_turn",
        usage: { input_tokens: 50, output_tokens: 5 }) }
    )
    lookup = Agentkit::ToolContract.new(name: :lookup, callable: -> { { balance: 42 } })
    result = Agentkit::Agent.new.run_loop("lookup", model: :native_anthropic, tools: [lookup], eager_tools: ["lookup"])
    expect(result).to be_answered
    expect(result.usage.input_tokens).to eq(110)
    expect(bodies.first["max_tokens"]).to eq(2_048)
    assistant = bodies.last["messages"].find { |message| message["role"] == "assistant" }
    expect(assistant["content"].first(2)).to eq(JSON.parse(JSON.generate(blocks.first(2))))
    expect(result.to_h.to_s).not_to include("private reasoning", "redacted-signed-block")
    expect(Agentkit::Audit.entries.map(&:to_h).to_s).not_to include("private reasoning", "signed-block")
    expect(stub).to have_been_requested.twice
  ensure
    RubyLLM.config.anthropic_api_key = old_key
    RubyLLM.models.all.delete(native_model) if native_model
  end

  it "recognizes an OpenAI refusal even when finish_reason is stop" do
    stub_request(:post, ENDPOINT).to_return(status: 200, headers: headers,
      body: response({ role: "assistant", content: nil, refusal: "not available" }))
    result = Agentkit::Agent.new.run_loop("x", model: :gateway)
    expect(result.stop_reason).to eq("refusal")
    expect(result.content).to be_nil
  end

  it "withholds native length-limited responses before calling their proposed tools" do
    called = false
    stub = stub_request(:post, ENDPOINT).to_return(status: 200, headers: headers, body: response({
      role: "assistant", content: "partial", tool_calls: [
        { id: "short", type: "function", function: { name: "lookup", arguments: '{}' } }
      ]
    }, finish: "length"))
    lookup = Agentkit::ToolContract.new(name: :lookup, callable: -> { called = true })
    result = Agentkit::Agent.new.run_loop("x", model: :gateway, tools: [lookup], eager_tools: ["lookup"])
    expect(result.stop_reason).to eq("max_tokens")
    expect(result.content).to be_nil
    expect(called).to be(false)
    expect(stub).to have_been_requested.once
  end
end
