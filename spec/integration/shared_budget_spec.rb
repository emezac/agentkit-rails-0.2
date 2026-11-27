# frozen_string_literal: true
require "rails_helper"

RSpec.describe Agentkit::SharedBudget, :integration, :real_concurrency do
  let(:k) { Agentkit::Knowledge }
  let(:context) { Agentkit::Context.new(tenant_key: "shop", account: 1, principal: "worker") }
  let(:operator) { Agentkit::Context.new(tenant_key: "shop", account: 1, principal: "operator") }
  let(:clock) { { now: Time.now.utc } }
  let(:permissions) { { enabled: true, journal: true } }
  let(:journal) { k::Journal.new(authorize: ->(*) { permissions[:journal] }) }
  let(:policy) do
    ->(action, _request, ctx) { permissions[:enabled] && (action != "reconcile" || ctx.principal == "operator") }
  end
  let(:budget) { described_class.new(journal: journal, authorize: policy, clock: -> { clock[:now] }) }
  let(:nodes) do
    [[], ["project"], ["project", "run"], ["project", "run", "agent"]].map do |path|
      { path: path, limits: { cost_microusd: 1000, tokens: 100, concurrency: 2 } }
    end
  end
  let(:deadline) { (clock[:now] + 60).iso8601(6) }
  let(:options) do
    { id: "billing-1", key: "call-1", path: %w[project run agent],
      amounts: { cost_microusd: 400, tokens: 30 }, expires_at: deadline, context: context }
  end

  before { budget.define(id: "billing-1", nodes: nodes, expires_at: (clock[:now] + 3600).iso8601(6), context: operator) }

  def totals
    budget.fetch(id: "billing-1", context: operator).fetch("usage").fetch("[]")
  end

  def settle(**changes)
    budget.settle(**{ id: "billing-1", key: "call-1", actual: { cost_microusd: 200, tokens: 20 },
      evidence: "provider:receipt-1", context: context }.merge(changes))
  end

  it "reserves all ancestors once and settles actual consumption once" do
    expect(budget.reserve(**options)["newly_reserved"]).to eq(true)
    expect(budget.reserve(**options)["newly_reserved"]).to eq(false)
    expect(totals).to eq("cost_microusd" => 400, "tokens" => 30, "concurrency" => 1)
    expect(settle["status"]).to eq("settled")
    settle
    expect(totals).to eq("cost_microusd" => 200, "tokens" => 20, "concurrency" => 0)
    budget.fetch(id: "billing-1", context: operator)["usage"].each_value { |usage| expect(usage).to eq(totals) }
  end

  it "shares root capacity across accounts while preserving reservation ownership" do
    budget.reserve(**options)
    second = Agentkit::Context.new(tenant_key: "shop", account: 2, principal: "worker")
    budget.reserve(**options.merge(key: "call-2", context: second))
    expect { budget.reserve(**options.merge(key: "call-3")) }.to raise_error(Agentkit::BudgetExceeded)
    expect { settle(context: second) }.to raise_error(k::AccessDenied)
    expect(totals["cost_microusd"]).to eq(800)
  end

  it "retains reservations across reconstruction and rejects conflicting replays" do
    budget.reserve(**options)
    reopened = described_class.new(journal: journal, authorize: policy, clock: -> { clock[:now] })
    expect(reopened.reserve(**options)["newly_reserved"]).to eq(false)
    expect { reopened.reserve(**options.merge(amounts: { cost_microusd: 1, tokens: 1 })) }.to raise_error(k::IntegrityError)
    settle
    expect { settle(evidence: "different") }.to raise_error(k::IntegrityError)
  end

  it "does not release unknown or expired work without reconciliation" do
    budget.reserve(**options)
    budget.unknown(id: "billing-1", key: "call-1", context: context)
    expect { settle }.to raise_error(k::AccessDenied)
    expect { settle(reconcile: true) }.to raise_error(k::AccessDenied)
    expect(totals["concurrency"]).to eq(1)
    settle(reconcile: true, context: operator)
    expect(totals["concurrency"]).to eq(0)
  end

  it "requires reconciliation for a measured result after expiry" do
    budget.reserve(**options)
    clock[:now] += 61
    expect(budget.reservation(id: "billing-1", key: "call-1", context: context)["overdue"]).to eq(true)
    expect { settle }.to raise_error(k::AccessDenied)
    settle(reconcile: true, context: operator)
  end

  it "records overspend without rolling back the bill and blocks later admission" do
    budget.reserve(**options)
    expect(settle(actual: { cost_microusd: 1100, tokens: 35 })["overrun"]).to eq(true)
    expect(totals["cost_microusd"]).to eq(1100)
    expect { budget.reserve(**options.merge(key: "next")) }.to raise_error(Agentkit::BudgetExceeded)
  end

  it "atomically enforces concurrent admission" do
    service, args = budget, options
    outcomes = 3.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          service.reserve(**args.merge(key: "call-#{index}"))
          :accepted
        rescue Agentkit::BudgetExceeded
          :denied
        end
      end
    end.map(&:value)
    expect(outcomes.count(:accepted)).to eq(2)
    expect(totals["concurrency"]).to eq(2)
  end

  it "rolls back usage when evidence cannot be recorded" do
    permissions[:journal] = false
    expect { budget.reserve(**options) }.to raise_error(k::AccessDenied)
    expect(totals["concurrency"]).to eq(0)
    expect(Agentkit::BudgetReservationRecord.count).to eq(0)
  end

  it "rejects tenant crossings, revoked authorization and uncommitted admission" do
    foreign = Agentkit::Context.new(tenant_key: "foreign", account: 1, principal: "worker")
    expect { budget.reserve(**options.merge(context: foreign)) }.to raise_error(ActiveRecord::RecordNotFound)
    Agentkit::SharedBudgetRecord.transaction do
      expect { budget.reserve(**options) }.to raise_error(k::InvalidContract)
    end
    budget.reserve(**options)
    permissions[:enabled] = false
    expect { budget.reserve(**options) }.to raise_error(k::AccessDenied)
    expect { settle }.to raise_error(k::AccessDenied)
  end

  it "rejects undeclared branches, malformed amounts and deadlines beyond the billing window" do
    expect { budget.reserve(**options.merge(path: ["other"])) }.to raise_error(k::InvalidContract)
    expect { budget.reserve(**options.merge(amounts: { cost_microusd: 1.5, tokens: 1 })) }.to raise_error(k::InvalidContract)
    expect { budget.reserve(**options.merge(expires_at: (clock[:now] + 7200).iso8601(6))) }.to raise_error(k::InvalidContract)
    expect(totals["concurrency"]).to eq(0)
  end

  it "keeps the hierarchy immutable and requires every ancestor" do
    expect { budget.define(id: "billing-1", nodes: nodes.first(1), expires_at: (clock[:now] + 3600).iso8601(6), context: operator) }.to raise_error(k::IntegrityError)
    expect { budget.define(id: "bad", nodes: [nodes.first, nodes.last], expires_at: deadline, context: operator) }.to raise_error(k::InvalidContract)
  end

  it "wraps measured work without automatically redispatching a duplicate key" do
    calls = 0
    run = -> { budget.run(**options, evidence: "provider:1", measure: ->(result) { result.fetch(:usage) }) do
      calls += 1
      { answer: "ok", usage: { cost_microusd: 100, tokens: 10 } }
    end }
    expect(run.call[:value][:answer]).to eq("ok")
    expect { run.call }.to raise_error(k::IntegrityError)
    expect(calls).to eq(1)
    expect(totals["cost_microusd"]).to eq(100)
  end

  it "holds the full reservation when work fails before reporting usage" do
    expect do
      budget.run(**options, evidence: "provider:1", measure: ->(result) { result }) { raise IOError }
    end.to raise_error(IOError)
    expect(budget.reservation(id: "billing-1", key: "call-1", context: context)["status"]).to eq("unknown")
    expect(totals["cost_microusd"]).to eq(400)
  end

  it "settles a measured AgentLoop subtree through the shared budget" do
    Agentkit::LLM::Adapters::Fake.respond_with_turns(content: "done", input_tokens: 10, output_tokens: 5)
    result = budget.run(**options, evidence: "loop:measured", measure: described_class.method(:loop_usage)) do
      Agentkit::Agent.new(context: context).run_loop("test")
    end
    expect(result.fetch(:value)).to be_answered
    expect(totals.fetch("tokens")).to eq(15)
  end

  it "retains the full reservation for an AgentLoop with unknown provider usage" do
    Agentkit::LLM::Adapters::Fake.respond_with_turns(IOError.new("provider unavailable"))
    expect do
      budget.run(**options, evidence: "loop:unknown", measure: described_class.method(:loop_usage)) do
        Agentkit::Agent.new(context: context).run_loop("test")
      end
    end.to raise_error(k::InvalidContract)
    expect(totals.fetch("tokens")).to eq(30)
    expect(budget.reservation(id: "billing-1", key: "call-1", context: context).fetch("status")).to eq("unknown")
  end
end
