# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Memory::KnowledgeGaps do
  let(:context) { Agentkit::Context.new(tenant_key: "acme", principal: "agent:revenue") }
  let(:other_tenant) { Agentkit::Context.new(tenant_key: "other", principal: "agent:revenue") }

  before do
    Agentkit.config.multi_tenant = true
    Agentkit.config.memory.store = :memory
  end

  it "flags gaps under the imagination firewall without polluting factual retrieval" do
    receipt = described_class.flag(
      kind: "stale",
      subject: "bigquery.revenue_columns",
      summary: "Column arr_v1 was renamed to arr_net in revenue_daily.",
      suggested_update: "Query arr_net instead of arr_v1.",
      evidence_refs: ["tool:bq_schema:abc123"],
      context: context
    )

    expect(receipt).to include(
      "kind" => "stale",
      "subject" => "bigquery.revenue_columns",
      "status" => "open",
      "untrusted_claim" => true,
      "authorizes" => false
    )
    expect(described_class.list(context: context).size).to eq(1)
    expect(described_class.list(context: other_tenant)).to be_empty

    # Imagination firewall: default factual Memory.recall does not return imagined gaps
    factual = Agentkit.with_context(context) do
      Agentkit::Memory.recall("arr_v1", mode: :keyword, embed_query: false, context: context)
    end
    expect(factual).to be_empty
  end

  it "requires an independent authorized reviewer to resolve or dismiss a gap" do
    receipt = described_class.flag(
      kind: "missing",
      subject: "policies/enterprise_refunds",
      summary: "No documented threshold for enterprise refunds.",
      context: context
    )

    # Reporter cannot resolve their own gap
    expect do
      described_class.resolve!(
        id: receipt["id"], actor: "agent:revenue",
        authorize: ->(*) { true }, resolution: "self approved", context: context
      )
    end.to raise_error(Agentkit::ConfigurationError, /cannot resolve their own gap/)

    # Unauthorized reviewer is denied
    expect do
      described_class.resolve!(
        id: receipt["id"], actor: "human:intern",
        authorize: ->(*) { false }, resolution: "fixed", context: context
      )
    end.to raise_error(Agentkit::ConfigurationError, /denied/)

    # Independent authorized reviewer resolves cleanly
    resolved = described_class.resolve!(
      id: receipt["id"], actor: "human:curator",
      authorize: ->(_gap, actor, _ctx) { actor == "human:curator" },
      resolution: "Added enterprise refund policy to wiki v2",
      context: context
    )
    expect(resolved["status"]).to eq("resolved")
    expect(described_class.list(status: "open", context: context)).to be_empty
    expect(described_class.list(status: "resolved", context: context).size).to eq(1)
  end

  it "can be exposed as an opt-in ToolContract inside AgentLoop" do
    Agentkit.config.llm.adapter = :fake
    Agentkit::LLM::Adapters::Fake.reset!
    Agentkit::LLM::Adapters::Fake.respond_with_turns(
      {
        tool_calls: [{
          "id" => "gap-1",
          "name" => "flag_knowledge_gap",
          "arguments" => {
            "kind" => "contradiction",
            "subject" => "metrics/arr_definition",
            "summary" => "Wiki excludes usage add-ons but finance query includes them."
          }
        }]
      },
      { content: "Report completed and knowledge gap flagged for curation." }
    )

    gap_tool = described_class.tool
    agent = Agentkit::Agent.new(context: context)
    outcome = agent.run_loop("Prepare ARR report", tools: [gap_tool], eager_tools: [:flag_knowledge_gap])

    expect(outcome).to be_answered
    gaps = described_class.list(status: "open", context: context)
    expect(gaps.size).to eq(1)
    expect(gaps.first.metadata["subject"]).to eq("metrics/arr_definition")
    expect(gaps.first.metadata["untrusted_claim"]).to be(true)
  end
end
