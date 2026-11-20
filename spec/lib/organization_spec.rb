# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Harness::Organization do
  let(:harness) { Agentkit::Harness }
  let(:digest) { ->(value) { harness.digest(value) } }
  let(:context) do
    account = AgentkitSpecHelpers::Account.new(7, "Acme", "growth")
    Agentkit::Context.new(account: account, principal: "user:42")
  end

  def member(agent, role: "domain", capabilities: ["research"], **extra)
    { agent: agent, role: role, capabilities: capabilities }.merge(extra)
  end

  def topology(id:, pattern:, members:, edges: [])
    described_class::Topology.new(id: id, pattern: pattern, members: members, edges: edges)
  end

  def run_observation(topology, suffix:, request: suffix, quality:, cost:, latency:, success: true,
                      checks: { "policy" => true }, **extra)
    {
      topology_digest: topology.digest,
      request_digest: digest.call("request-#{request}"),
      evidence_digest: digest.call("evidence-#{suffix}"),
      success: success, quality: quality, cost_usd: cost,
      latency_ms: latency, checks: checks
    }.merge(extra)
  end

  it "records redacted organizational telemetry and aggregates nested model usage" do
    solo = topology(id: "solo", pattern: "single", members: [member("researcher")])
    result = described_class.instrument(
      request_id: "private-request-42", organization_id: "research-team",
      topology: solo, agent: "researcher", role: "domain", capability: "research",
      model_profile: "fast", toolset_digest: digest.call("tools"), context: context
    ) do |measures, child|
      expect(Agentkit::Context.current).to equal(child)
      Agentkit::Telemetry.emit("llm.call", dims: { model: "test" },
        measures: { input_tokens: 20, output_tokens: 5, cost_usd: 0.03, retries: 1 })
      measures.merge!(success: true, quality: 0.9, context_bytes: 800,
        retries: 2, verifier_rejections: 0)
      :measured
    end

    expect(result).to eq(:measured)
    calls = emitted("organization.call")
    expect(calls.size).to eq(1)
    call = calls.fetch(0)
    expect(call.dims).to include(
      tenant: "acct:7", account_id: 7, organization_id: "research-team",
      request_digest: digest.call("private-request-42"), agent: "researcher"
    )
    expect(call.measures).to include(
      success: true, input_tokens: 20, output_tokens: 5,
      cost_usd: 0.03, llm_retries: 1, llm_calls: 1
    )
    expect(call.to_h.to_s).not_to include("private-request-42")
    expect(emitted("llm.call").fetch(0).dims).to include(organization_id: "research-team")
  end

  it "exports scoped telemetry to DelegationDiagnostics without raw request data" do
    team = topology(
      id: "support-pipeline", pattern: "pipeline",
      members: [member("orders"), member("shipping", capabilities: ["shipping"])],
      edges: [{ from: "orders", to: "shipping", kind: "handoff" }]
    )
    2.times do |index|
      request = "customer-secret-#{index}"
      described_class.instrument(request_id: request, organization_id: "support",
        topology: team, agent: "orders", role: "domain", capability: "orders",
        context: context) do |measures|
        measures.merge!(success: true, context_bytes: 100, handoffs: 1,
          failed_handoffs: 0, context_retention: 1.0)
      end
      described_class.instrument(request_id: request, organization_id: "support",
        topology: team, agent: "shipping", role: "domain", capability: "shipping",
        handoff_from: "orders", context: context) do |measures|
        measures.merge!(success: true, context_bytes: 80, context_retention: 0.8)
      end
    end

    traces = described_class::TraceSet.from_telemetry(context: context)
    report = traces.analyze(minimum_requests: 2, context: context)

    expect(traces.incomplete).to eq("success" => 0, "context_bytes" => 0)
    expect(report.to_h).to include("request_count" => 2, "call_count" => 4)
    expect(report.to_h.dig("coordination", "handoffs")).to eq(2)
    expect(report.to_h.fetch("agents").flat_map { |row| row["observed_capabilities"] })
      .to contain_exactly("orders", "shipping")
    expect(report.to_h.to_s).not_to include("customer-secret")
  end

  it "never lets invalid measurements break the operation being measured" do
    solo = topology(id: "solo", pattern: "single", members: [member("researcher")])

    result = described_class.instrument(
      request_id: "request-1", organization_id: "research-team",
      topology: solo, agent: "researcher", role: "domain", capability: "research",
      context: context
    ) do |measures|
      measures[:quality] = "not-a-number"
      :business_result
    end

    expect(result).to eq(:business_result)
    call = emitted("organization.call").fetch(0)
    expect(call.dims).to include(status: "measurement_error",
      error_class: "Agentkit::HarnessExperimentError")
    expect(call.measures).not_to have_key(:quality)
  end

  it "builds immutable evidence-bound multidimensional agent profiles" do
    profile = described_class::AgentProfile.build(
      agent: "researcher",
      identity: { model_profile: "fast", skills_digest: digest.call("skills") },
      observations: [
        { capability: "research", task_digest: digest.call("task-1"),
          evidence_digest: digest.call("evidence-1"), success: true,
          quality: 0.8, cost_usd: 0.02, latency_ms: 100 },
        { capability: "research", task_digest: digest.call("task-2"),
          evidence_digest: digest.call("evidence-2"), success: false,
          quality: 0.4, cost_usd: 0.01, latency_ms: 80 },
        { capability: "verification", task_digest: digest.call("task-3"),
          evidence_digest: digest.call("evidence-3"), success: true,
          quality: 0.9, cost_usd: 0.03, latency_ms: 120 }
      ],
      coordination_observations: [
        { evidence_digest: digest.call("handoff-1"), handoff_success: true,
          context_retention: 0.75, conflict: false, retries: 1 }
      ]
    )

    expect(profile.capabilities.fetch("research")).to include(
      "samples" => 2, "success_rate" => 0.5, "mean_quality" => 0.6
    )
    expect(profile.coordination).to include(
      "handoff_success_rate" => 1.0, "mean_context_retention" => 0.75
    )
    expect(profile.evidence_digests.size).to eq(4)
    expect { profile.capabilities["research"]["samples"] = 9 }.to raise_error(FrozenError)
  end

  it "compares topology scaling without collapsing tradeoffs into one score" do
    solo = topology(id: "solo", pattern: "single",
      members: [member("generalist", capabilities: %w[research writing])])
    pair = topology(
      id: "specialists", pattern: "pipeline",
      members: [member("researcher"), member("writer", capabilities: ["writing"])],
      edges: [{ from: "researcher", to: "writer" }]
    )
    workload = described_class::WorkloadContract.new(
      id: "market-brief", capabilities: %w[research writing], required_checks: ["policy"],
      max_agents: 3, max_cost_usd: 0.1, max_latency_ms: 500, minimum_samples: 2
    )
    observations = [
      run_observation(solo, suffix: "s1", request: "r1", quality: 0.6, cost: 0.05, latency: 200),
      run_observation(solo, suffix: "s2", request: "r2", quality: 0.6, cost: 0.05, latency: 200),
      run_observation(pair, suffix: "p1", request: "r1", quality: 0.8, cost: 0.04, latency: 180,
        handoffs: 1, context_retention: 0.9),
      run_observation(pair, suffix: "p2", request: "r2", quality: 0.8, cost: 0.04, latency: 180,
        handoffs: 1, context_retention: 0.9)
    ]

    report = described_class::CoordinationReport.build(
      workload: workload, topologies: [solo, pair], baseline: solo,
      observations: observations
    )
    comparison = report.comparisons.fetch(pair.digest)

    expect(comparison["relationship"]).to eq("pareto_better")
    expect(comparison.fetch("coordination_return")).to include(
      "matched_requests" => true, "quality_delta" => 0.2,
      "cost_ratio" => 0.8, "latency_ratio" => 0.9
    )
    expect(report.summaries.fetch(pair.digest)).to include(
      "capability_coverage" => 1.0, "missing_capabilities" => []
    )
    expect(report.to_h.to_s).not_to include("market brief body")
    expect { report.summaries.clear }.to raise_error(FrozenError)
  end

  it "blocks incomplete, unsafe or over-budget organizational evidence" do
    expect do
      topology(id: "unsafe", pattern: "verifier",
        members: [member("reviewer", role: "verifier")])
    end.to raise_error(Agentkit::HarnessExperimentError, /isolation/)

    solo = topology(id: "solo", pattern: "single", members: [member("generalist")])
    pair = topology(id: "pair", pattern: "pipeline",
      members: [member("one"), member("two")], edges: [{ from: "one", to: "two" }])
    workload = described_class::WorkloadContract.new(
      id: "bounded", capabilities: ["research"], required_checks: ["policy"],
      max_agents: 2, max_cost_usd: 0.05, max_latency_ms: 100, minimum_samples: 2
    )
    observations = [
      run_observation(solo, suffix: "s1", request: "r1", quality: 0.5, cost: 0.02, latency: 80),
      run_observation(solo, suffix: "s2", request: "r2", quality: 0.5, cost: 0.02, latency: 80),
      run_observation(pair, suffix: "p1", request: "r1", quality: 0.9, cost: 0.1, latency: 80),
      run_observation(pair, suffix: "p2", request: "r2", quality: 0.9, cost: 0.1, latency: 80)
    ]
    report = described_class::CoordinationReport.build(
      workload: workload, topologies: [solo, pair], baseline: solo,
      observations: observations
    )

    expect(report.comparisons.dig(pair.digest, "relationship")).to eq("blocked")
  end

  it "blocks unmatched workloads and incomplete declared capability coverage" do
    solo = topology(id: "solo", pattern: "single",
      members: [member("generalist", capabilities: %w[research writing])])
    pair = topology(id: "pair", pattern: "parallel",
      members: [member("one"), member("two")])
    workload = described_class::WorkloadContract.new(
      id: "matched", capabilities: %w[research writing], required_checks: ["policy"],
      max_agents: 2, max_cost_usd: 1, max_latency_ms: 1_000, minimum_samples: 2
    )
    observations = [
      run_observation(solo, suffix: "s1", request: "r1", quality: 0.5, cost: 0.02, latency: 80),
      run_observation(solo, suffix: "s2", request: "r2", quality: 0.5, cost: 0.02, latency: 80),
      run_observation(pair, suffix: "p1", request: "r1", quality: 0.9, cost: 0.02, latency: 80),
      run_observation(pair, suffix: "p2", request: "different", quality: 0.9, cost: 0.02, latency: 80)
    ]

    report = described_class::CoordinationReport.build(
      workload: workload, topologies: [solo, pair], baseline: solo,
      observations: observations
    )

    expect(report.summaries.dig(pair.digest, "missing_capabilities")).to eq(["writing"])
    expect(report.comparisons.dig(pair.digest, "relationship")).to eq("blocked")
    expect(report.comparisons.dig(pair.digest, "coordination_return", "matched_requests")).to be(false)
  end
end
