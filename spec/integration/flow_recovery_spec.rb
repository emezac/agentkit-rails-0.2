# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Flow checkpoint recovery over ActiveRecord", :integration do
  let(:account) { account! }
  let(:executions) { [] }
  let(:process_callbacks) { [] }
  let(:flow) do
    observed = executions
    callbacks = process_callbacks
    Class.new(Agentkit::Flow) do
      def self.name = "ARCheckpointRecoveryFlow#{object_id}"

      step(:process) do
        observed << :process
        callbacks.shift&.call
        "processed"
      end
      step(:record) do |ctx|
        observed << :record
        ctx[:process].value
      end
    end
  end

  before do
    Agentkit::Flow.dispatcher = Agentkit::Flow::Dispatcher::TestQueue.new
  end

  def checkpoint(run, status:)
    started_at = Time.now if status == "running"
    Agentkit::RunStepRecord.create!(run_id: run.id, step_key: "process", step_name: "process",
                                    kind: "step", status: status, position: 1,
                                    started_at: started_at, tenant_key: run.tenant_key)
  end

  def advance(run)
    scope = { tenant_key: run.tenant_key, account_id: run.account_id }
    Agentkit::Flow::Worker.advance(run.run_id, scope)
  end

  it "executes an existing pending step once and persists its result" do
    run = with_account(account) { flow.perform_later }
    step = checkpoint(run, status: "pending")
    redelivery = nil
    process_callbacks << -> { redelivery = advance(run) }

    advance(run)
    advance(run)

    expect(redelivery).to be_err
    expect(executions).to eq(%i[process record])
    expect(step.reload.status).to eq("completed")
    expect(step.attempt_count).to eq(1)
    expect(Agentkit::Flow::Coder.load(step.output.fetch("result")).value).to eq("processed")
    expect(Agentkit::RunRecord.find(run.id).status).to eq("completed")
  end

  it "stops at a running step whose outcome was never recorded" do
    run = with_account(account) { flow.perform_later }
    checkpoint(run, status: "running")

    result = advance(run)

    expect(result).to be_err
    expect(executions).to be_empty
    expect(Agentkit::RunRecord.find(run.id).status).not_to eq("completed")
    expect(Agentkit::RunStepRecord.exists?(run_id: run.id, step_key: "record")).to be(false)
  end

  it "persists an expired deadline before executing the next pending step" do
    run = with_account(account) { flow.perform_later }
    checkpoint(run, status: "pending")
    row = Agentkit::RunRecord.find(run.id)
    row.update!(deadline_at: Time.now - 1)

    result = advance(run)

    expect(result).to be_err
    expect(result.error).to be_a(Agentkit::RunTimedOut)
    expect(executions).to be_empty
    expect(row.reload.status).to eq("timed_out")
    expect(row.finished_at).to be_present
  end

  it "persists a timeout when the last step returns after the deadline" do
    clock = Time.utc(2026, 1, 1)
    allow(Time).to receive(:now) { clock }
    final_step_flow = Class.new(Agentkit::Flow) do
      def self.name = "ARFinalStepDeadlineFlow"

      timeout 10
      step(:finalize) do
        clock += 11
        "late result"
      end
    end

    result = final_step_flow.call

    expect(result).to be_err
    expect(result.error).to be_a(Agentkit::RunTimedOut)
    row = Agentkit::RunRecord.find(result.run.id)
    expect(row.status).to eq("timed_out")
    expect(row.finished_at).to be > row.deadline_at
    expect(final_step_flow.resume(row.run_id).error).to be_a(Agentkit::RunTimedOut)
  end
end
