# frozen_string_literal: true

require "rails_helper"

class OperatorWorkflowFlow < Agentkit::Flow
  input :message
  step(:complete) { |ctx| ctx.input[:message] }
end

class MandatedToolFlow < Agentkit::Flow
  step(:call_tool) do |ctx|
    Agentkit::ToolContract.new(name: :private_lookup, callable: -> { "sensitive" }).invoke(context: ctx.context).result
  end
end

class AcceptedWorkflowFlow < Agentkit::Flow
  input :number
  step(:normalize, accept: ->(value, _ctx) { value.even? },
    repair: ->(value, _ctx, _attempt, _reason) { value + 1 }, max_repairs: 1) { |ctx| ctx.input[:number] }
  step(:finish) { |ctx| ctx[:normalize].value * 2 }
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
    Agentkit::TaskMandate.authorizer = nil
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

  it "persists acceptance evidence and rejected fingerprints across an async Flow" do
    Agentkit::Flow::Registry.register(AcceptedWorkflowFlow)
    receipt = Agentkit::Delegations.dispatch!(flow: AcceptedWorkflowFlow,
      input: { number: 3 }, context: context)
    Agentkit::Flow.dispatcher.drain

    row = Agentkit::RunRecord.find_by!(run_id: receipt.run_id)
    step = row.steps.find_by!(step_name: "normalize")
    expect(row.status).to eq("completed")
    expect(step.output.dig("acceptance", "verdict")).to eq("accepted")
    expect(step.attempts.count { |item| item["kind"] == "acceptance_rejected" }).to eq(1)
    expect(row.steps.find_by!(step_name: "finish").output.dig("result", "value")).to eq(8)
  end

  it "holds a mandated run when its policy changes and resumes after authorization returns" do
    allowed = true
    Agentkit::TaskMandate.authorizer = ->(data, _phase, _ctx) { allowed && data["policy_version"] == "v1" }
    mandate = Agentkit::TaskMandate.issue(flow: "OperatorWorkflowFlow", source: "github",
      resource: "org/repo", thread: "issue:42", policy_version: "v1", context: context)
    receipt = Agentkit::Delegations.dispatch!(flow: OperatorWorkflowFlow,
      input: { message: "review" }, context: context, mandate: mandate)
    expect(Agentkit::RunRecord.find_by!(run_id: receipt.run_id).context.dig("metadata", "task_mandate", "digest")).to be_present
    expect { Agentkit::TaskMandate.guard_run!(Agentkit::Flow.shared_store.find_run_by_uuid(receipt.run_id,
      scope: { tenant_key: context.tenant_key, account_id: account.id })) }.not_to raise_error

    allowed = false
    expect { OperatorWorkflowFlow.resume(receipt.run_id, context: context, mode: :sync) }
      .to raise_error(Agentkit::PolicyDenied)
    Agentkit::Flow::Worker.advance(receipt.run_id, { tenant_key: context.tenant_key, account_id: account.id })
    expect(Agentkit::RunRecord.find_by!(run_id: receipt.run_id).status).to eq("waiting_human")
    expect(Agentkit::RunStepRecord.where(run_id: Agentkit::RunRecord.find_by!(run_id: receipt.run_id).id)).to be_empty

    allowed = true
    expect { Agentkit::TaskMandate.guard_run!(Agentkit::Flow.shared_store.find_run_by_uuid(receipt.run_id,
      scope: { tenant_key: context.tenant_key, account_id: account.id })) }.not_to raise_error
    Agentkit::Flow::Worker.advance(receipt.run_id, { tenant_key: context.tenant_key, account_id: account.id })
    expect(Agentkit::RunRecord.find_by!(run_id: receipt.run_id).status).to eq("completed")
  end

  it "stops an already queued fan-out branch when its mandate is revoked" do
    Agentkit::Flow::Registry.register(DummyFlow)
    allowed = true
    Agentkit::TaskMandate.authorizer = ->(_data, _phase, _ctx) { allowed }
    widget = Widget.create!(account: account, name: "mandated")
    mandate = Agentkit::TaskMandate.issue(flow: "DummyFlow", source: "github",
      resource: "org/repo", thread: "issue:77", policy_version: "v1", context: context)
    receipt = Agentkit::Delegations.dispatch!(flow: DummyFlow, input: { widget: widget },
      context: context, mandate: mandate)
    queue = Agentkit::Flow.dispatcher
    queue.drain(limit: 1)
    expect(Agentkit::RunRecord.find_by!(run_id: receipt.run_id).status).to eq("waiting_join")

    allowed = false
    queue.drain(limit: 1)
    expect(Agentkit::RunRecord.find_by!(run_id: receipt.run_id).status).to eq("waiting_human")
    expect(Agentkit::RunStepRecord.where(kind: "branch", status: "completed").count).to eq(0)

    allowed = true
    branch = Agentkit::RunStepRecord.where(kind: "branch", status: "pending").first
    Agentkit::Flow::Worker.run_branch(receipt.run_id, branch.id,
      { tenant_key: context.tenant_key, account_id: account.id })
    queue.drain
    expect(Agentkit::RunRecord.find_by!(run_id: receipt.run_id).status).to eq("completed")
  end

  it "preserves tool restrictions when manually resuming a task" do
    Agentkit::Flow::Registry.register(MandatedToolFlow)
    Agentkit::TaskMandate.authorizer = ->(*) { true }
    mandate = Agentkit::TaskMandate.issue(flow: "MandatedToolFlow", source: "github",
      resource: "org/repo", thread: "issue:88", policy_version: "v1", context: context)
    receipt = Agentkit::Delegations.dispatch!(flow: MandatedToolFlow, input: {},
      context: context, mandate: mandate)
    expect { MandatedToolFlow.resume(receipt.run_id, context: context, mode: :sync) }
      .not_to raise_error
    expect(Agentkit::RunRecord.find_by!(run_id: receipt.run_id).status).to eq("failed")
  end

  it "deduplicates source events and routes only to the subscribed task" do
    Agentkit::TaskMandate.authorizer = ->(_data, _phase, _ctx) { true }
    mandate = Agentkit::TaskMandate.issue(flow: "OperatorWorkflowFlow", source: "github",
      resource: "org/repo", thread: "issue:42", policy_version: "v1", context: context)
    receipt = Agentkit::Delegations.dispatch!(flow: OperatorWorkflowFlow,
      input: { message: "review" }, context: context, mandate: mandate)
    Agentkit::TaskEvents.subscribe!(run_id: receipt.run_id, context: context)
    auth = ->(_source, _resource, _thread, _event, _ctx) { true }
    event = { "kind" => "comment", "text" => "CI failed" }
    first = Agentkit::TaskEvents.ingest!(source: "github", resource: "org/repo", thread: "issue:42",
      event_id: "comment:9", payload: event, context: context, authorize: auth)
    second = Agentkit::TaskEvents.ingest!(source: "github", resource: "org/repo", thread: "issue:42",
      event_id: "comment:9", payload: event, context: context, authorize: auth)
    expect(first).to eq(second)
    expect(first[:run_id]).to eq(receipt.run_id)
    expect(Agentkit::TaskEvents.pending(run_id: receipt.run_id, context: context).size).to eq(1)
    expect(Agentkit::TaskEvents.metrics(run_id: receipt.run_id, context: context)[:events_received]).to eq(1)
    expect { Agentkit::TaskEvents.ingest!(source: "github", resource: "org/repo", thread: "issue:42",
      event_id: "comment:9", payload: { "text" => "changed" }, context: context, authorize: auth) }
      .to raise_error(Agentkit::IdempotencyConflict)

    Agentkit::TaskEvents.mark_consumed!(run_id: receipt.run_id, event_key: first[:event_key], context: context)
    expect(Agentkit::TaskEvents.pending(run_id: receipt.run_id, context: context)).to be_empty
    expect(Agentkit::TaskEvents.prune_consumed!(before: 1.minute.from_now, context: context,
      authorize: ->(_action, _ctx) { true })).to eq(1)
    expect(Agentkit::TaskEventRecord.find_by!(event_key: first[:event_key]).payload).to eq({})
    expect(Agentkit::TaskEvents.ingest!(source: "github", resource: "org/repo", thread: "issue:42",
      event_id: "comment:9", payload: event, context: context, authorize: auth)).to eq(first)
    expect(Agentkit::TaskEvents.ingest!(source: "github", resource: "org/repo", thread: "issue:43",
      event_id: "comment:10", payload: event, context: context, authorize: auth)).to be_nil
  end

  it "refuses an event from an unauthenticated source or another tenant" do
    Agentkit::TaskMandate.authorizer = ->(_data, _phase, _ctx) { true }
    mandate = Agentkit::TaskMandate.issue(flow: "OperatorWorkflowFlow", source: "github",
      resource: "org/repo", thread: "issue:42", policy_version: "v1", context: context)
    receipt = Agentkit::Delegations.dispatch!(flow: OperatorWorkflowFlow,
      input: { message: "review" }, context: context, mandate: mandate)
    Agentkit::TaskEvents.subscribe!(run_id: receipt.run_id, context: context)
    expect { Agentkit::TaskEvents.ingest!(source: "github", resource: "org/repo", thread: "issue:42",
      event_id: "comment:9", payload: { "text" => "x" }, context: context,
      authorize: ->(*) { false }) }.to raise_error(Agentkit::PolicyDenied)
    other = account!(name: "Other")
    other_context = Agentkit::Context.new(account: other, principal: "operator:2")
    expect(Agentkit::TaskEvents.ingest!(source: "github", resource: "org/repo", thread: "issue:42",
      event_id: "comment:9", payload: { "text" => "x" }, context: other_context,
      authorize: ->(*) { true })).to be_nil
    expect { Agentkit::TaskEvents.pending(run_id: receipt.run_id, context: other_context) }
      .to raise_error(ActiveRecord::RecordNotFound)
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
