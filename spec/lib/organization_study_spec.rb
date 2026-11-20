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
    Agentkit::Harness::Organization::CompositionStudy.new(
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


  describe Agentkit::Harness::Organization::CompositionPilot do
    def pilot_options(study, recommendation)
      now = Time.now.utc
      {
        study: study,
        recommendation: recommendation,
        version: "1",
        unit: "account",
        metrics: {
          "quality" => { "min" => 0, "max" => 100,
                         "direction" => "maximize", "max_harm" => 0 },
          "cost_cents" => { "min" => 0, "max" => 10_000,
                            "direction" => "minimize", "max_harm" => 0 }
        },
        primary_metric: "quality",
        starts_at: (now + 60).iso8601(6),
        enrollment_ends_at: (now + 3_600).iso8601(6),
        analysis_at: (now + 7_200).iso8601(6),
        window_seconds: 60,
        max_units: 40,
        min_per_arm: 20,
        gates: {
          "control" => digest.call("control-gate"),
          "treatment" => digest.call("treatment-gate")
        },
        measurement_versions: { "quality_ledger" => "v1", "cost_ledger" => "v1" },
        journal: Object.new,
        authorize: ->(*) { true },
        eligible: ->(*) { true },
        bind_unit: ->(*) { true }
      }
    end

    it "binds the P2 evidence to a durable two-arm pilot without promoting it" do
      study = build_study
      recommendation = study.recommend

      pilot = described_class.new(**pilot_options(study, recommendation))

      expect(pilot.protocol.fetch("variants").dig("control", "topology_digest"))
        .to eq(baseline.digest)
      expect(pilot.protocol.fetch("variants").dig("treatment", "topology_digest"))
        .to eq(pair.digest)
      expect(pilot.protocol.fetch("evidence_versions")).to include(
        "composition_study" => study.digest,
        "composition_recommendation" => recommendation.digest
      )
      expect(pilot.to_h).to include("auto_promoted" => false, "authorizes" => false)
      expect(emitted("llm.call")).to be_empty
    end

    it "refuses to pilot a retained or ambiguous recommendation" do
      holdout = {
        "solo" => { quality: 0.6, cost: 0.1, latency: 200 },
        "pair" => { quality: 0.8, cost: 0.2, latency: 180 }
      }
      study = build_study(holdout_metrics: holdout)

      expect do
        described_class.new(**pilot_options(study, study.recommend))
      end.to raise_error(Agentkit::PolicyDenied, /reviewable P2 candidate/)
    end

    it "resolves only the assigned approved topology inside gated execution" do
      study = build_study
      recommendation = study.recommend
      fake_experiment = instance_double(Agentkit::Knowledge::BusinessExperiment)
      allow(Agentkit::Knowledge::BusinessExperiment).to receive(:new).and_return(fake_experiment)
      allow(fake_experiment).to receive(:execute)
        .and_yield("treatment", { "topology_digest" => pair.digest })
      pilot = described_class.new(**pilot_options(study, recommendation))
      received = nil

      result = pilot.execute(
        unit_id: "account-1", gate: Object.new,
        arguments: { account_id: 1 }, context: context
      ) do |arm, assigned_topology|
        received = [arm, assigned_topology]
        :host_result
      end

      expect(result).to eq(:host_result)
      expect(received).to eq(["treatment", pair])
    end


    describe Agentkit::Harness::Organization::CompositionGovernance do
      before do
        Agentkit.config.exploration.store = :memory
        Agentkit::Exploration::Governance.store =
          Agentkit::Exploration::Governance::Stores::Memory.new
      end

      def pilot_with_review(version: "1", revoked: false, analysis_status: "eligible_for_human_review")
        study = build_study
        recommendation = study.recommend
        options = pilot_options(study, recommendation).merge(version: version)
        pilot = Agentkit::Harness::Organization::CompositionPilot.new(**options)
        analysis = {
          "status" => analysis_status,
          "protocol" => pilot.protocol,
          "counts" => {
            "control" => { "assigned" => 20, "complete" => 20 },
            "treatment" => { "assigned" => 20, "complete" => 20 }
          },
          "auto_promoted" => false
        }
        final_review = {
          "approved" => true,
          "actor" => "pilot-reviewer",
          "report_digest" => Agentkit::Knowledge.digest(analysis),
          "auto_promoted" => false
        }
        records = {
          "analysis" => analysis,
          "final_review" => final_review,
          "revocation" => revoked ? { "reason" => "invalid measurement" } : nil
        }
        allow(pilot.experiment).to receive(:fetch) do |type:, **_arguments|
          records.fetch(type)
        end
        pilot
      end

      it "adopts an independently reviewed pilot as a reversible durable binding" do
        pilot = pilot_with_review
        review = described_class.submit!(target: "support", pilot: pilot, context: context)

        expect(review.status).to eq("pending")
        expect(described_class.binding(target: "support", context: context)).to be_nil
        expect do
          described_class.approve!(
            review, actor: "pilot-reviewer", reason: "self approval",
            authorize: ->(*) { true }, context: context
          )
        end.to raise_error(Agentkit::PolicyDenied, /independent/)

        approved = described_class.approve!(
          review, actor: "organization-owner", reason: "reviewed P3 evidence",
          authorize: ->(*) { true }, context: context
        )
        binding = described_class.binding(target: "support", context: context)
        expect(approved.status).to eq("approved")
        expect(binding.policy_digest).to eq(pair.digest)
        expect(binding.generation).to eq(1)

        resolved = described_class.resolve(
          target: "support", resolver: ->(topology_digest, _ctx) {
            topology_digest == pair.digest ? pair : nil
          }, authorize: ->(*) { true }, context: context
        )
        expect(resolved).to equal(pair)

        rolled_back = described_class.rollback!(
          approved, actor: "organization-owner", reason: "canary regression",
          authorize: ->(*) { true }, context: context
        )
        expect(rolled_back.status).to eq("rolled_back")
        expect(described_class.binding(target: "support", context: context)).to be_nil
      end

      it "rejects revoked or inconclusive pilot evidence" do
        expect do
          described_class.submit!(
            target: "support", pilot: pilot_with_review(revoked: true), context: context
          )
        end.to raise_error(Agentkit::PolicyDenied, /approved, unrevoked/)

        expect do
          described_class.submit!(
            target: "support",
            pilot: pilot_with_review(version: "2", analysis_status: "inconclusive"),
            context: context
          )
        end.to raise_error(Agentkit::PolicyDenied, /approved, unrevoked/)
      end

      it "serializes competing adoptions against the active incumbent" do
        first = described_class.submit!(
          target: "support", pilot: pilot_with_review(version: "1"), context: context
        )
        second = described_class.submit!(
          target: "support", pilot: pilot_with_review(version: "2"), context: context
        )
        described_class.approve!(
          first, actor: "owner-one", reason: "first reviewed result",
          authorize: ->(*) { true }, context: context
        )

        expect do
          described_class.approve!(
            second, actor: "owner-two", reason: "stale reviewed result",
            authorize: ->(*) { true }, context: context
          )
        end.to raise_error(Agentkit::DecisionConflict, /incumbent changed/)
      end

      it "fails closed when resolution returns anything except the bound topology" do
        review = described_class.submit!(
          target: "support", pilot: pilot_with_review, context: context
        )
        described_class.approve!(
          review, actor: "organization-owner", reason: "activate",
          authorize: ->(*) { true }, context: context
        )

        expect do
          described_class.resolve(
            target: "support", resolver: ->(*) { baseline },
            authorize: ->(*) { true }, context: context
          )
        end.to raise_error(Agentkit::HarnessIntegrityError, /stale topology/)
      end
    end
  end
end
