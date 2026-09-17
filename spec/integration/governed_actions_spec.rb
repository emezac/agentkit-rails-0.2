# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Governed actions persistence", :integration do
  let(:account) { account! }
  let(:tenant) { account.tenant_key }
  let(:requester) do
    Agentkit::Principal.new(id: "user:1", tenant_key: tenant, permissions: ["orders.write"])
  end
  let(:approver) do
    Agentkit::Principal.new(id: "reviewer:2", tenant_key: tenant, permissions: ["orders.write"])
  end

  before do
    Agentkit::Capability.register :ship_order do |cap|
      cap.input_schema type: "object", properties: { order_id: { type: "integer" } },
                       required: ["order_id"], additionalProperties: false
      cap.effect :internal
      cap.risk :irreversible
      cap.required_permission "orders.write"
      cap.executor { |arguments| { shipped: arguments[:order_id] } }
    end
  end

  it "recovers an approved action from the transactional outbox" do
    context = Agentkit::Context.new(account: account, principal: requester)
    invocation = Agentkit::Actions.invoke(capability: :ship_order,
                                          arguments: { order_id: 12 }, principal: requester,
                                          context: context)
    Agentkit::Actions.dispatcher = ->(*) { raise "queue unavailable" }
    Agentkit::Actions.decide!(invocation[:proposal].id, decision: :approved,
                             actor: approver, scope: { tenant_key: tenant })

    expect(Agentkit::Actions.fetch!(invocation[:proposal].id,
                                    scope: { tenant_key: tenant }).status).to eq("approved")
    expect(Agentkit::ActionOutboxRecord.find_by!(proposal_id: invocation[:proposal].id).status).to eq("pending")

    Agentkit::Actions.dispatcher = lambda do |proposal_id, scope|
      Agentkit::Actions.execute!(proposal_id, scope: scope)
    end
    Agentkit::Actions.dispatch_pending!
    expect(Agentkit::Actions.fetch!(invocation[:proposal].id,
                                    scope: { tenant_key: tenant }).status).to eq("executed")
  end

  it "serializes concurrent audit writers into one valid tenant chain", :real_concurrency do
    tenant_key = "concurrent-audit"
    threads = 8.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Agentkit::Audit.record(event_type: "concurrent.#{index}", payload: { index: index },
                                 context: Agentkit::Context.new(tenant_key: tenant_key,
                                                                principal: "worker:#{index}"),
                                 failure_mode: :required)
        end
      end
    end
    threads.each(&:value)

    expect(Agentkit::Audit.verify!(tenant_key: tenant_key))
      .to include(valid: true, entries: 8)
    expect(Agentkit::AuditRecord.where(tenant_key: tenant_key).pluck(:sequence).sort)
      .to eq((1..8).to_a)
  end

  it "allows exactly one concurrent action decision", :real_concurrency do
    account = Account.create!(name: "Decision tenant", plan: "pro")
    tenant_key = account.tenant_key
    requester = Agentkit::Principal.new(id: "user:1", tenant_key: tenant_key,
                                        permissions: ["orders.write"])
    context = Agentkit::Context.new(account: account, principal: requester)
    proposal = Agentkit::Actions.propose!(capability: :ship_order,
                                          arguments: { order_id: 91 },
                                          requester: requester, context: context)
    Agentkit::Actions.dispatcher = ->(*) { nil }

    results = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          actor = Agentkit::Principal.new(id: "reviewer:#{index}", tenant_key: tenant_key,
                                          permissions: ["orders.write"])
          Agentkit::Actions.decide!(proposal.id, decision: :approved, actor: actor,
                                    scope: { tenant_key: tenant_key })
          :approved
        rescue Agentkit::ActionTransitionConflict
          :conflict
        end
      end
    end.map(&:value)

    expect(results).to contain_exactly(:approved, :conflict)
    expect(Agentkit::ActionDecisionRecord.where(proposal_id: proposal.id).count).to eq(1)
    expect(Agentkit::ActionOutboxRecord.where(proposal_id: proposal.id).count).to eq(1)
  end

  it "deduplicates concurrent action redelivery in PostgreSQL", :real_concurrency do
    account = Account.create!(name: "Replay tenant", plan: "pro")
    tenant_key = account.tenant_key
    requester = Agentkit::Principal.new(id: "user:1", tenant_key: tenant_key,
                                        permissions: ["orders.write"])

    ids = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          context = Agentkit::Context.new(account: account, principal: requester)
          Agentkit::Actions.propose!(capability: :ship_order,
                                    arguments: { order_id: 44 }, requester: requester,
                                    idempotency_key: "delivery-44", context: context).id
        end
      end
    end.map(&:value)

    expect(ids.uniq.size).to eq(1)
    expect(Agentkit::ActionProposalRecord.where(tenant_key: tenant_key,
                                                 idempotency_key: "delivery-44").count).to eq(1)
  end
end
