# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Agent do
  let(:agent_class) do
    Class.new(described_class) do
      uses_skills :context_spec
      prompt_id :context_spec

      def domain_context = "Domain procedures"
    end
  end

  before do
    Agentkit.config.hitl.level = :strict
    Agentkit::Skill.define(:context_spec) do |skill|
      skill.prompt "Skill instructions"
      skill.tool(:lookup) { :unused }
    end
  end

  it "combines the registered prompt with agent context and default tools" do
    Agentkit::Prompt.define(:context_spec, version: 2) { |ctx| "Versioned instructions for #{ctx.tenant_key}" }
    context = Agentkit::Context.new(tenant_key: "tenant:test")

    agent_class.new(context: context).complete("Review the record")

    call = fake_llm.calls.last
    expect(call.system).to start_with("## Agent Identity")
    expect(call.system).to include("## Autonomy Level\nSTRICT:", "Skill instructions", "Domain procedures",
                                   "Versioned instructions for tenant:test")
    expect(call.tools.map(&:name)).to eq([:lookup])
    expect(emitted("llm.call").last.dims[:prompt_version]).to eq(2)
  end

  it "passes an explicit system prompt through unchanged with the default tools" do
    Agentkit::Prompt.define(:context_spec, body: "Versioned instructions")

    agent_class.new.complete("Review the record", system: "Caller instructions")

    call = fake_llm.calls.last
    expect(call.system).to eq("Caller instructions")
    expect(call.tools.map(&:name)).to eq([:lookup])
    expect(emitted("llm.call").last.dims[:prompt_version]).to be_nil
  end

  it "rejects an oversized registered prompt before calling the model" do
    Agentkit::Prompt.define(:context_spec, body: "Versioned instructions\n#{'x' * 20_000}")

    expect { agent_class.new.complete("Review the record") }
      .to raise_error(Agentkit::ConfigurationError, /system context budget/)
    expect(fake_llm.calls).to be_empty
  end
end
