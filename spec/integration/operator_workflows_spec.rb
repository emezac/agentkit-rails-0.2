# frozen_string_literal: true

require "rails_helper"

class OperatorWorkflowFlow < Agentkit::Flow
  input :message
  step(:complete) { |ctx| ctx.input[:message] }
end

RSpec.describe "Operator workflows", :integration do
  let(:account) { account! }
  let(:context) do
    Agentkit::Context.new(account: account, tenant_key: account.tenant_key,
                          principal: "operator:1")
  end

  before do
    Agentkit::Flow::Registry.register(OperatorWorkflowFlow)
    Agentkit.config.flow.dispatcher = :test
    Agentkit::Flow.dispatcher = nil
  end

  after do
    Agentkit.config.flow.dispatcher = :active_job
    Agentkit::Flow.dispatcher = nil
  end

  it "claims each scheduled occurrence once and keeps its Flow receipt" do
    due = 2.minutes.from_now
    routine = Agentkit::Routines.create!(
      name: "Daily brief", flow_name: "OperatorWorkflowFlow", schedule_kind: "once",
      time_zone: "America/Mexico_City", at: due, input: { message: "hello" }, context: context
    )

    expect(Agentkit::Routines.tick!(at: due + 1.second)).to eq(1)
    expect(Agentkit::Routines.tick!(at: due + 1.second)).to eq(0)
    occurrence = routine.occurrences.first
    expect(routine.reload.status).to eq("paused")

    expect(Agentkit::Routines.dispatch!(occurrence.id)).to be_nil
    expect(occurrence.reload.status).to eq("dispatched")
    expect(occurrence.flow_run_id).to be_present
    expect(Agentkit::RunRecord.where(run_id: occurrence.flow_run_id).count).to eq(1)
  end

  it "skips a nonexistent daylight-saving wall time" do
    after = Time.utc(2026, 3, 8, 6, 30) # 01:30 in New York before the spring jump
    next_at = Agentkit::Routines.next_daily(after, "America/New_York", 2, 30)
    expect(next_at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-09 02:30")
  end

  it "isolates memory proposals, records decisions, and archives an undo" do
    proposal = Agentkit::MemoryReviews.propose!(
      content: "Acme prefers concise reports", tags: %w[acme preference],
      source_agent: "ResearchAgent", context: context
    )
    expect(Agentkit::MemoryRecord.where(content: proposal.content)).to be_empty

    Agentkit::MemoryReviews.approve!(proposal.id, actor: "operator:1", context: context)
    expect(proposal.reload.status).to eq("approved")
    expect(Agentkit::MemoryRecord.find(proposal.memory_id).status).not_to eq("archived")

    other = account!
    other_context = Agentkit::Context.new(account: other, tenant_key: other.tenant_key,
                                          principal: "operator:2")
    expect { Agentkit::MemoryReviews.undo!(proposal.id, actor: "operator:2", context: other_context) }
      .to raise_error(ActiveRecord::RecordNotFound)

    Agentkit::MemoryReviews.undo!(proposal.id, actor: "operator:1", context: context)
    expect(Agentkit::MemoryRecord.find(proposal.memory_id).status).to eq("archived")
    expect(proposal.review_events.order(:id).pluck(:event)).to eq(%w[proposed approved undone])
    expect { proposal.review_events.first.update!(actor: "tampered") }
      .to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "does not embed an archived review proposal during a later batch flush" do
    Agentkit.config.memory.embedding.policy = :batched
    Agentkit.config.memory.embedding.batch_size = 100
    proposal = Agentkit::MemoryReviews.propose!(content: "temporary fact", context: context)
    Agentkit::MemoryReviews.approve!(proposal.id, actor: "operator:1", context: context)
    proposal.reload
    expect(Agentkit::MemoryRecord.find(proposal.memory_id).embedding_status).to eq("pending")

    Agentkit::MemoryReviews.undo!(proposal.id, actor: "operator:1", context: context)
    expect(Agentkit.with_context(context) { Agentkit::Memory.embedder.flush! }).to eq(0)
  end

  it "returns a tenant-scoped receipt for an asynchronous Flow delegation" do
    receipt = Agentkit::Delegations.dispatch!(
      flow: OperatorWorkflowFlow, input: { message: "research" }, context: context
    )
    expect(Agentkit::Delegations.receipt(receipt.run_id, context: context).status).to eq("pending")

    other = account!
    other_context = Agentkit::Context.new(account: other, tenant_key: other.tenant_key,
                                          principal: "operator:2")
    expect(Agentkit::Delegations.receipt(receipt.run_id, context: other_context)).to be_nil
  end

  it "keeps the attention inbox behind the existing console guard" do
    status, = Rails.application.call(Rack::MockRequest.env_for("/agentkit/attention"))
    expect(status).to eq(404)

    Agentkit.config.console.enabled = true
    Agentkit.config.console.principal_resolver = -> { "operator:1" }
    Agentkit.config.console.guard = ->(_principal) { true }
    status, = Rails.application.call(Rack::MockRequest.env_for("/agentkit/attention"))
    expect(status).to eq(200)
  end
end
