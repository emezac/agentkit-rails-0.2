# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Harness::Organization::CompositionStudy do
  let(:organization) { Agentkit::Harness::Organization }
  let(:digest) { ->(value) { Agentkit::Harness.digest(value) } }
  let(:context) do
    account = AgentkitSpecHelpers::Account.new(9, "Organization", "growth")
    Agentkit::Context.new(account: account, principal: "operator:7")
  end
  let(:workload) do
    organization::WorkloadContract.new(
      id: "research-workload", capabilities: ["research"], required_checks: ["policy"],
      max_agents: 3, max_cost_usd: 1, max_latency_ms: 1_000, minimum_samples: 2
    )
  end
  let(:baseline) do
    topology("solo", [{ agent: "generalist", role: "domain",
                         capabilities: ["research"], model_profile: "fast" }])
  end
  let(:pair) do
    topology(
      "pair",
      [
        { agent: "researcher", role: "research",
          capabilities: ["research"], model_profile: "fast" },
        { agent: "reviewer", role: "verifier", capabilities: ["verification"],
          model_profile: "fast", independent_context: true }
      ],
      pattern: "verifier",
      edges: [{ from: "researcher", to: "reviewer", kind: "verification" }]
    )
  end

  def topology(id, members, pattern: "single", edges: [])
    organization::Topology.new(id: id, pattern: pattern, members: members, edges: edges)
  end

  def profile(agent, capabilities:, model_profile: "fast")
    observations = capabilities.flat_map do |capability|
      2.times.map do |index|
        {
          capability: capability,
          task_digest: digest.call("#{agent}-#{capability}-task-#{index}"),
          evidence_digest: digest.call("#{agent}-#{capability}-evidence-#{index}"),
          success: true, quality: 0.8, cost_usd: 0.01, latency_ms: 10
        }
      end
    end
    organization::AgentProfile.build(
      agent: agent, identity: { model_profile: model_profile }, observations: observations
    )
  end

  def profiles_for(*topologies, overrides: {})
    topologies.flat_map(&:members).reject { |member| member.fetch("role") == "tool" }
      .uniq { |member| member.fetch("agent") }.map do |member|
        overrides.fetch(member.fetch("agent")) do
          profile(member.fetch("agent"), capabilities: member.fetch("capabilities"))
        end
      end
  end

  def report(topologies, phase:, metrics:)
    observations = topologies.flat_map do |candidate|
      2.times.map do |index|
        values = metrics.fetch(candidate.id)
        {
          topology_digest: candidate.digest,
          request_digest: digest.call("#{phase}-request-#{index}"),
          evidence_digest: digest.call("#{phase}-#{candidate.id}-evidence-#{index}"),
          success: values.fetch(:success, true),
          quality: values.fetch(:quality), cost_usd: values.fetch(:cost),
          latency_ms: values.fetch(:latency), checks: { policy: true },
          handoffs: candidate.size - 1, context_retention: 0.9
        }
      end
    end
    organization::CoordinationReport.build(
      workload: workload, topologies: topologies, baseline: baseline,
      observations: observations
    )
  end

  def build_study(topologies: [baseline, pair], training_metrics: nil,
                  holdout_metrics: nil, profiles: nil, authorize: nil)
    defaults = {
      "solo" => { quality: 0.6, cost: 0.1, latency: 200 },
      "pair" => { quality: 0.8, cost: 0.08, latency: 180 }
    }
    training = report(topologies, phase: "training", metrics: training_metrics || defaults)
    holdout = report(topologies, phase: "holdout", metrics: holdout_metrics || defaults)
    described_class.new(
      id: "research-composition", training_report: training, holdout_report: holdout,
      profiles: profiles || profiles_for(*topologies),
      approved_topology_digests: topologies.map(&:digest), approved_by: "operator-7",
      approval_evidence_digest: digest.call("approval"),
      authorize: authorize || ->(_action, _request, _context) { true }, context: context
    )
  end

  it "recommends one holdout-proven composition for review without granting authority" do
    authorization = nil
    study = build_study(authorize: lambda { |action, request, received_context|
      authorization = [action, request, received_context]
      true
    })

    recommendation = study.recommend

    expect(authorization.first).to eq("evaluate_composition")
    expect(authorization.last).to equal(context)
    expect(recommendation.status).to eq("recommend_review")
    expect(recommendation.selected_digest).to eq(pair.digest)
    expect(recommendation).to be_requires_review
    expect(recommendation.auto_promoted?).to be(false)
    expect(recommendation.authorizes?).to be(false)
    expect(recommendation.shortlist.first).to include(
      "topology_id" => "pair", "mean_cost_usd" => 0.08
    )
    expect(emitted("llm.call")).to be_empty
  end

  it "retains the baseline when holdout evidence is only a tradeoff" do
    holdout = {
      "solo" => { quality: 0.6, cost: 0.1, latency: 200 },
      "pair" => { quality: 0.8, cost: 0.2, latency: 180 }
    }

    recommendation = build_study(holdout_metrics: holdout).recommend

    expect(recommendation.status).to eq("retain")
    expect(recommendation.selected_digest).to be_nil
    expect(recommendation.blockers.fetch(pair.digest)).to include("holdout_not_pareto_better")
  end

  it "keeps multiple non-dominated improvements as an explicit human choice" do
    faster = topology("faster", [
      { agent: "fast-agent", role: "domain", capabilities: ["research"], model_profile: "fast" }
    ])
    cheaper = topology("cheaper", [
      { agent: "cheap-agent", role: "domain", capabilities: ["research"], model_profile: "fast" }
    ])
    topologies = [baseline, faster, cheaper]
    metrics = {
      "solo" => { quality: 0.6, cost: 0.1, latency: 200 },
      "faster" => { quality: 0.9, cost: 0.09, latency: 150 },
      "cheaper" => { quality: 0.8, cost: 0.05, latency: 170 }
    }

    recommendation = build_study(
      topologies: topologies, training_metrics: metrics, holdout_metrics: metrics
    ).recommend

    expect(recommendation.status).to eq("needs_choice")
    expect(recommendation.selected_digest).to be_nil
    expect(recommendation.shortlist.map { |entry| entry.fetch("topology_id") })
      .to contain_exactly("faster", "cheaper")
  end

  it "rejects reused training evidence and stale topology approvals" do
    metrics = {
      "solo" => { quality: 0.6, cost: 0.1, latency: 200 },
      "pair" => { quality: 0.8, cost: 0.08, latency: 180 }
    }
    same_report = report([baseline, pair], phase: "same", metrics: metrics)

    expect do
      described_class.new(
        id: "overlap", training_report: same_report, holdout_report: same_report,
        profiles: profiles_for(baseline, pair),
        approved_topology_digests: [baseline.digest, pair.digest], approved_by: "operator-7",
        approval_evidence_digest: digest.call("approval"),
        authorize: ->(*) { true }, context: context
      )
    end.to raise_error(Agentkit::HarnessIntegrityError, /overlap/)

    expect do
      training = report([baseline, pair], phase: "training", metrics: metrics)
      holdout = report([baseline, pair], phase: "holdout", metrics: metrics)
      described_class.new(
        id: "stale", training_report: training, holdout_report: holdout,
        profiles: profiles_for(baseline, pair), approved_topology_digests: [baseline.digest],
        approved_by: "operator-7", approval_evidence_digest: digest.call("approval"),
        authorize: ->(*) { true }, context: context
      )
    end.to raise_error(Agentkit::PolicyDenied, /approval set/)
  end

  it "fails closed when the authenticated host denies the study" do
    expect do
      build_study(authorize: ->(_action, _request, _context) { false })
    end.to raise_error(Agentkit::PolicyDenied, /denied/)
  end

  it "blocks a candidate whose component identity drifted after profiling" do
    drifted = profile("researcher", capabilities: ["research"], model_profile: "changed")
    profiles = profiles_for(baseline, pair, overrides: { "researcher" => drifted })

    recommendation = build_study(profiles: profiles).recommend

    expect(recommendation.status).to eq("retain")
    expect(recommendation.blockers.fetch(pair.digest)).to include(
      "identity_mismatch:researcher:model_profile"
    )
  end
end
