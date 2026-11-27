# frozen_string_literal: true
require "rails_helper"

RSpec.describe Agentkit::Harness::OperationalProjection, :integration, :real_concurrency do
  let(:k) { Agentkit::Knowledge }
  let(:clock) { { now: Time.now.utc } }
  let(:account) { Account.create!(name: "Projection", plan: "pro") }
  let(:operator) { Agentkit::Context.new(account: account, principal: "operator") }
  let(:foreign) { Agentkit::Context.new(tenant_key: "other", account: account, principal: "operator") }
  let(:allow_read) { { value: true } }
  let(:journal) { k::Journal.new(authorize: ->(*) { true }) }
  let(:escalations) do
    Agentkit::Operations::Escalations.new(journal: journal, authorize: ->(*) { true }, clock: -> { clock[:now] })
  end
  let(:runs) do
    Agentkit::Harness::UnattendedRun.new(journal: journal, authorize: ->(*) { true },
      escalations: escalations, clock: -> { clock[:now] })
  end
  let(:budgets) do
    Agentkit::SharedBudget.new(journal: journal, authorize: ->(*) { true }, clock: -> { clock[:now] })
  end
  let(:projection) do
    described_class.new(runs: runs, budgets: budgets, escalations: escalations,
      authorize: ->(_action, _ids, _context) { allow_read[:value] }, clock: -> { clock[:now] })
  end
  let(:artifact) do
    { commit_sha: "a" * 40, configuration_digest: "sha256:#{'b' * 64}",
      dependencies_digest: "sha256:#{'c' * 64}", protected_digest: "sha256:#{'d' * 64}",
      reference: "sandbox:artifact", digest: "sha256:#{'e' * 64}" }
  end

  before do
    goal = Agentkit::Harness::Goal.new(id: "fix", objective: "Fix checkout",
      criteria: [{ id: "tests", description: "Acceptance checks pass" }],
      protected_resources: ["tests/"], max_steps: 2)
    gate = Agentkit::Harness::VerificationGate.new(id: "tests", description: "Acceptance")
    runs.start(id: "night", goal: goal, gates: [gate], artifact: artifact,
      allowed_resources: ["src/"], protected_resources: ["tests/"],
      executor_version: "runner:1", limits: { max_attempts: 2, max_cost_microusd: 1000,
        max_tokens: 1000, run_seconds: 600, call_seconds: 60,
        cost_per_call_microusd: 100, tokens_per_call: 100, stall_limit: 2 },
      primary: "on-call", fallback: "owner", context: operator)
    budgets.define(id: "billing", nodes: [{ path: [], limits: {
      cost_microusd: 1000, tokens: 1000, concurrency: 2 } }],
      expires_at: (clock[:now] + 3600).iso8601(6), context: operator)
  end

  def view(context: operator)
    projection.fetch(run_id: "night", budget_id: "billing", context: context)
  end

  it "combines scoped run evidence and budget without returning lease tokens or escalation targets" do
    budget_reservation = budgets.reserve(id: "billing", key: "call-1", path: [],
      amounts: { cost_microusd: 200, tokens: 100 },
      expires_at: (clock[:now] + 60).iso8601(6), context: operator)
    lease = runs.claim(id: "night", role: "verifier", request_id: "baseline", context: operator)
    result = view
    expect(result).to include("status" => "verifying", "authorizes" => false,
      "point_in_time" => false, "requires_operator" => true)
    expect(result.dig("budget", "remaining", "cost_microusd")).to eq(800)
    expect(result.dig("evidence", "usage_complete")).to eq(false)
    expect(result.dig("evidence", "commit_sha")).to eq("a" * 40)
    expect(result.dig("goal", "required_gates")).to eq(["tests"])
    expect(result.to_s).not_to include(lease.fetch("lease").fetch("token"), "on-call", "owner")
    expect(budget_reservation.fetch("newly_reserved")).to eq(true)
  end

  it "surfaces terminal escalation and budget overrun as separate blockers" do
    budgets.reserve(id: "billing", key: "call-1", path: [],
      amounts: { cost_microusd: 200, tokens: 100 },
      expires_at: (clock[:now] + 60).iso8601(6), context: operator)
    budgets.settle(id: "billing", key: "call-1",
      actual: { cost_microusd: 1200, tokens: 100 }, evidence: "provider:bill",
      context: operator)
    runs.cancel(id: "night", reason: "manual", context: operator)
    result = view
    expect(result.fetch("blockers")).to include("run:needs_approval", "budget:over_limit", "escalation:unacknowledged")
    expect(result.dig("escalation", "status")).to eq("open")
    expect(result.fetch("outcome")).to be_nil
  end

  it "honors source scope and projection revocation on every read" do
    expect(view(context: foreign)).to be_nil
    allow_read[:value] = false
    expect { view }.to raise_error(k::AccessDenied)
  end

  it "refuses a missing budget or a mismatched escalation reference" do
    expect do
      projection.fetch(run_id: "night", budget_id: "other", context: operator)
    end.to raise_error(ActiveRecord::RecordNotFound)
    allow(escalations).to receive(:fetch).and_return("incident_id" => "different")
    expect { view }.to raise_error(k::IntegrityError)
  end

  it "keeps the Rails console page closed until a trusted resolver is configured" do
    path = "/agentkit/operations/night"
    expect(Rails.application.call(Rack::MockRequest.env_for(path)).first).to eq(404)
    Agentkit.config.console.enabled = true
    Agentkit.config.console.principal_resolver = -> { "operator" }
    Agentkit.config.console.guard = ->(*) { true }
    expect(Rails.application.call(Rack::MockRequest.env_for(path)).first).to eq(404)
    Agentkit.config.console.operational_view = ->(id, _ctx) { projection.fetch(run_id: id, budget_id: "billing", context: operator) }
    status, _headers, body = Rails.application.call(Rack::MockRequest.env_for(path))
    expect(status).to eq(200)
    html = body.each.to_a.join
    expect(html).to include("Presupuesto disponible", "night")
    expect(html).not_to include("on-call", "owner")
  ensure
    Agentkit.config.console.enabled = false
    Agentkit.config.console.guard = nil
    Agentkit.config.console.principal_resolver = nil
    Agentkit.config.console.operational_view = nil
  end
end
