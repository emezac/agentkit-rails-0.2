# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Actions do
  let(:requester) do
    Agentkit::Principal.new(id: "user:1", tenant_key: "acme", permissions: ["orders.write"])
  end
  let(:approver) do
    Agentkit::Principal.new(id: "reviewer:2", tenant_key: "acme", permissions: ["orders.write"])
  end
  let(:context) { Agentkit::Context.new(tenant_key: "acme", principal: requester) }

  before do
    Agentkit.config.actions.store = :memory
    Agentkit.config.audit.store = :memory
    Agentkit::Capability.register :close_order do |cap|
      cap.input_schema type: "object", properties: { order_id: { type: "integer" } },
                       required: ["order_id"], additionalProperties: false
      cap.output_schema type: "object", properties: { closed: { type: "boolean" } },
                        required: ["closed"], additionalProperties: false
      cap.effect :internal
      cap.risk :irreversible
      cap.required_permission "orders.write"
      cap.executor { |_arguments| { closed: true } }
    end
  end

  it "keeps proposal, authorization, attempt and outcome as distinct facts" do
    invocation = described_class.invoke(capability: :close_order,
                                        arguments: { order_id: 7 }, principal: requester,
                                        mode: :execute, context: context)
    proposal = invocation.fetch(:proposal)
    expect(proposal.status).to eq("open")
    expect(invocation[:status]).to eq("pending_approval")

    expect do
      described_class.decide!(proposal.id, decision: :approved, actor: requester)
    end.to raise_error(Agentkit::SeparationOfDutiesViolation)

    described_class.decide!(proposal.id, decision: :approved, actor: approver)
    executed = described_class.fetch!(proposal.id)
    described_class.observe_outcome!(proposal.id, kind: :business_value,
                                     value: 12, source: :billing)

    expect(executed.status).to eq("executed")
    expect(described_class.decisions(proposal.id).one?).to be(true)
    expect(described_class.attempts(proposal.id).map(&:status)).to eq(["executed"])
    expect(described_class.outcomes(proposal.id).map(&:kind)).to eq(["business_value"])
    expect(Agentkit::Receipt.action(proposal.id)[:arguments_digest]).to start_with("sha256:")
  end

  it "deduplicates the same durable request and rejects conflicting reuse" do
    one = described_class.propose!(capability: :close_order, arguments: { order_id: 1 },
                                   requester: requester, idempotency_key: "request-1",
                                   context: context)
    two = described_class.propose!(capability: :close_order, arguments: { order_id: 1 },
                                   requester: requester, idempotency_key: "request-1",
                                   context: context)
    expect(two.id).to eq(one.id)

    expect do
      described_class.propose!(capability: :close_order, arguments: { order_id: 2 },
                               requester: requester, idempotency_key: "request-1",
                               context: context)
    end.to raise_error(Agentkit::IdempotencyConflict)
  end

  it "marks an ambiguous external effect unknown and reconciles before retry" do
    calls = 0
    Agentkit::Capability.register :charge_card do |cap|
      cap.input_schema type: "object", properties: { cents: { type: "integer" } },
                       required: ["cents"], additionalProperties: false
      cap.effect :external
      cap.risk :irreversible
      cap.required_permission "orders.write"
      cap.idempotency :required
      cap.reconciliation :required
      cap.executor { |_arguments, **| calls += 1; raise Timeout::Error }
      cap.reconciler { |_arguments, **| { status: :executed, external_result_ref: "processor:42" } }
    end

    invocation = described_class.invoke(capability: :charge_card, arguments: { cents: 500 },
                                        principal: requester, idempotency_key: "charge-1",
                                        context: context)
    described_class.decide!(invocation[:proposal].id, decision: :approved, actor: approver)
    expect(described_class.fetch!(invocation[:proposal].id).status).to eq("execution_unknown")

    reconciled = described_class.reconcile!(invocation[:proposal].id)
    expect(reconciled.status).to eq("executed")
    expect(calls).to eq(1)
  end

  it "implements only the documented static transitions" do
    expect(described_class::StateMachine.allowed?("draft", "open")).to be(true)
    expect(described_class::StateMachine.allowed?("open", "executing")).to be(false)
    expect(described_class::StateMachine.allowed?("execution_unknown", "executing")).to be(true)
  end


  it "keeps HITL approval as a compatibility shim over the decision service" do
    invocation = described_class.invoke(capability: :close_order,
                                        arguments: { order_id: 8 }, principal: requester,
                                        context: context)
    result = Agentkit::HITL.approve(invocation[:task_id], actor: approver)

    expect(result.status).to eq("executed")
    expect(described_class.decisions(result.id).last.actor_principal_id).to eq("reviewer:2")
  end
end
