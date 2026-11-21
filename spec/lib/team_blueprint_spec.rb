# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Harness::Organization::TeamBlueprint do
  let(:harness) { Agentkit::Harness }
  let(:organization) { harness::Organization }
  let(:digest) { ->(value) { harness.digest(value) } }

  def goal
    Agentkit::Harness::Goal.new(
      id: "weekly-brief-goal",
      objective: "Produce an evidence-bound weekly market brief",
      criteria: [
        { id: "citations", description: "Every claim has a source" },
        { id: "policy", description: "The brief passes policy review" }
      ],
      required_approvals: %w[publish quality_review],
      required_outputs: ["brief"],
      require_verification: true,
      max_steps: 20
    )
  end

  def workload
    organization::WorkloadContract.new(
      id: "weekly-market-brief",
      capabilities: %w[research synthesis verification],
      required_checks: %w[citations policy],
      max_agents: 3,
      max_cost_usd: 1.0,
      max_latency_ms: 10_000,
      max_human_minutes: 30,
      minimum_samples: 3
    )
  end

  def baseline
    organization::Topology.new(
      id: "brief-generalist",
      pattern: :single,
      members: [
        {
          agent: "generalist", role: "domain",
          capabilities: %w[research synthesis verification],
          model_profile: "balanced"
        }
      ]
    )
  end

  def candidate
    organization::Topology.new(
      id: "brief-research-review",
      pattern: :coordinator,
      members: [
        { agent: "coordinator", role: "coordinator", capabilities: ["synthesis"] },
        { agent: "researcher", role: "research", capabilities: ["research"] },
        {
          agent: "reviewer", role: "verifier", capabilities: ["verification"],
          independent_context: true
        }
      ],
      edges: [
        { from: "coordinator", to: "researcher", kind: "handoff" },
        { from: "researcher", to: "reviewer", kind: "verification" },
        { from: "reviewer", to: "coordinator", kind: "handoff" }
      ]
    )
  end

  def agent_contract(agent, responsibility:, purpose:, separation_reason:,
                     done_checks:, tools: [], does_not: [])
    {
      agent: agent,
      responsibility: responsibility,
      purpose: purpose,
      does_not: does_not,
      input_schema_digest: digest.call("#{agent}-input"),
      output_schema_digest: digest.call("#{agent}-output"),
      done_checks: done_checks,
      tools: tools,
      prompt_reference: "prompts/#{agent}/v1",
      prompt_digest: digest.call("#{agent}-prompt-v1"),
      separation_reason: separation_reason
    }
  end

  def agents
    [
      agent_contract("generalist", responsibility: "end_to_end_brief",
        purpose: "baseline_comparison", separation_reason: "baseline",
        done_checks: %w[citations policy], tools: ["search"]),
      agent_contract("coordinator", responsibility: "coordinate_and_assemble",
        purpose: "single_user_interface", separation_reason: "user_interface",
        done_checks: ["policy"], tools: ["publish"],
        does_not: ["independent_verification"]),
      agent_contract("researcher", responsibility: "source_research",
        purpose: "specialized_research", separation_reason: "specialized_capability",
        done_checks: ["citations"], tools: ["search"]),
      agent_contract("reviewer", responsibility: "independent_review",
        purpose: "verify_brief", separation_reason: "independent_verification",
        done_checks: ["policy"], does_not: ["draft_brief"])
    ]
  end

  def tools
    [
      {
        name: "search", purpose: "retrieve_sources",
        owners: %w[generalist researcher], effect: "read_only", risk: "read",
        contract_digest: digest.call("search-contract"), approval_gate: nil
      },
      {
        name: "publish", purpose: "publish_approved_brief",
        owners: ["coordinator"], effect: "external", risk: "irreversible",
        contract_digest: digest.call("publish-contract"), approval_gate: "publish"
      }
    ]
  end

  def handoffs
    candidate.edges.map do |edge|
      {
        from: edge.fetch("from"), to: edge.fetch("to"), kind: edge.fetch("kind"),
        contract_digest: digest.call(edge.values_at("from", "to", "kind")),
        required_checks: edge.fetch("kind") == "verification" ? ["policy"] : [],
        on_failure: "return_to_coordinator"
      }
    end
  end

  def workflow
    [
      {
        id: "plan", owner: "coordinator", kind: "intake", depends_on: [],
        done_checks: [], effect: "read_only", approval_gate: nil
      },
      {
        id: "research", owner: "researcher", kind: "work", depends_on: ["plan"],
        done_checks: ["citations"], effect: "read_only", approval_gate: nil
      },
      {
        id: "verify", owner: "reviewer", kind: "verification", depends_on: ["research"],
        done_checks: ["policy"], effect: "read_only", approval_gate: nil
      },
      {
        id: "decide", owner: "coordinator", kind: "decision", depends_on: ["verify"],
        done_checks: %w[citations policy], effect: "read_only", approval_gate: nil
      }
    ]
  end

  def quality
    {
      required_checks: %w[citations policy], minimum_success_rate: 0.9,
      verifier: "reviewer", external_gate: "quality_review",
      training_set_digest: digest.call("training-set"),
      holdout_set_digest: digest.call("holdout-set"),
      grader_digest: digest.call("grader-v1"),
      human_review: true, rollback_required: true
    }
  end

  def budget
    {
      max_turns: 12, max_model_calls: 16, max_subcalls: 8,
      max_delegation_depth: 2, max_cost_usd: 0.8,
      max_latency_ms: 8_000, max_human_minutes: 20
    }
  end

  def launch_plan(candidate_present: true)
    kinds = candidate_present ? described_class::LAUNCH_KINDS_WITH_CANDIDATE :
      described_class::LAUNCH_KINDS_BASELINE_ONLY
    kinds.map.with_index(1) do |kind, day|
      {
        day: day, kind: kind,
        owner: %w[review pilot_decision].include?(kind) ? "human_operator" : "generalist",
        deliverable_reference: "launch/day-#{day}/#{kind}",
        deliverable_digest: digest.call("launch-#{day}-#{kind}"),
        requires_approval: %w[review pilot_decision].include?(kind)
      }
    end
  end

  def output_contract
    {
      type: "object",
      properties: {
        "brief_reference" => { type: "string" },
        "evidence_digest" => { type: "string" }
      },
      required: %w[brief_reference evidence_digest],
      additionalProperties: false
    }
  end

  def attributes
    {
      id: "weekly-market-brief-team",
      intake: {
        business_domain: "market_research", desired_outcome: "weekly_brief",
        operator_strengths: ["editorial_judgment"], weekly_hours: 10,
        first_delegation: "source_research"
      },
      goal: goal,
      selected_use_case: {
        id: "weekly_brief", objective: "evidence_bound_brief",
        rationale: "largest_bounded_time_saving", first_metric: "accepted_briefs",
        expected_hours_saved: 4, evidence_digest: digest.call("selection-evidence"),
        capabilities: %w[research synthesis verification]
      },
      deferred_use_cases: [{ id: "outreach", reason: "higher_external_risk" }],
      workload: workload, baseline: baseline, candidate: candidate,
      agents: agents, tools: tools, handoffs: handoffs, workflow: workflow,
      quality: quality, budget: budget, launch_plan: launch_plan,
      output_contract: output_contract,
      metadata: {
        source_reference: "onboarding/session-42",
        source_digest: digest.call("onboarding-session-42"), labels: ["pilot"]
      }
    }
  end

  it "builds an immutable, review-only candidate blueprint" do
    blueprint = described_class.new(**attributes)

    expect(blueprint.status).to eq("ready_for_evaluation")
    expect(blueprint).to be_ready_for_evaluation
    expect(blueprint.authorizes?).to be(false)
    expect(blueprint.auto_activates?).to be(false)
    expect(blueprint.requires_review?).to be(true)
    expect(blueprint.to_h).to include(
      "authorizes" => false, "auto_activates" => false,
      "requires_review" => true, "baseline_required" => true,
      "holdout_required" => true
    )
    expect { blueprint.agents.first.fetch("tools") << "other" }
      .to raise_error(FrozenError)
    expect(described_class.questions.map { |entry| entry.fetch("id") }).to eq(
      %w[business_domain desired_outcome operator_strengths weekly_hours first_delegation]
    )
  end

  it "supports a baseline-only design without pretending a team was evaluated" do
    attrs = attributes
    attrs[:candidate] = nil
    attrs[:agents] = [agents.first]
    attrs[:tools] = [tools.first.merge(owners: ["generalist"])]
    attrs[:handoffs] = []
    attrs[:workflow] = [
      {
        id: "decide", owner: "generalist", kind: "decision", depends_on: [],
        done_checks: %w[citations policy], effect: "read_only", approval_gate: nil
      }
    ]
    attrs[:quality] = quality.merge(verifier: nil)
    attrs[:budget] = budget.merge(max_subcalls: 0, max_delegation_depth: 0)
    attrs[:launch_plan] = launch_plan(candidate_present: false)

    blueprint = described_class.new(**attrs)

    expect(blueprint.status).to eq("baseline_ready")
    expect(blueprint).not_to be_ready_for_evaluation
    expect(blueprint.authorizes?).to be(false)
  end

  it "round-trips deterministically and rejects altered authority flags" do
    blueprint = described_class.new(**attributes)
    restored = described_class.from_h(blueprint.to_h)

    expect(restored.digest).to eq(blueprint.digest)
    expect(restored.to_h).to eq(blueprint.to_h)

    tampered = Marshal.load(Marshal.dump(blueprint.to_h))
    tampered["authorizes"] = true
    expect { described_class.from_h(tampered) }
      .to raise_error(Agentkit::HarnessExperimentError, /safety flags/)
  end

  it "emits a declarative manifest without execution or activation authority" do
    flows_before = Agentkit::Flow::Registry.all.dup
    capabilities_before = Agentkit::Capability.available.dup
    telemetry_before = Agentkit::Telemetry::Backends::MemoryBackend.instance.size
    blueprint = described_class.new(**attributes)

    manifest = blueprint.to_manifest(topology: :candidate)
    baseline_manifest = blueprint.to_manifest(topology: :baseline)

    expect(manifest.metadata).to include(
      "authorizes" => false, "auto_activates" => false,
      "requires_review" => true, "blueprint_digest" => blueprint.digest,
      "topology" => "candidate", "topology_digest" => candidate.digest
    )
    expect(manifest.components).to all(satisfy do |component|
      component.activation.fetch("authorizes") == false && component.permissions.empty?
    end)
    expect(manifest.component_keys).to include(
      "subagent:agent/coordinator", "tool_guidance:tool/publish",
      "guardrail:team-blueprint/weekly-market-brief-team"
    )
    expect(manifest.component_keys).not_to include("subagent:agent/generalist")
    expect(baseline_manifest.component_keys).to include(
      "subagent:agent/generalist", "tool_guidance:tool/search"
    )
    expect(baseline_manifest.component_keys).not_to include(
      "subagent:agent/coordinator", "tool_guidance:tool/publish"
    )
    expect(blueprint.to_manifests.keys).to contain_exactly("baseline", "candidate")
    expect(llm_calls).to eq(0)
    expect(emitted("llm.call")).to be_empty
    expect(Agentkit::Flow::Registry.all).to eq(flows_before)
    expect(Agentkit::Capability.available).to eq(capabilities_before)
    expect(Agentkit::Telemetry::Backends::MemoryBackend.instance.size).to eq(telemetry_before)
  end

  it "rejects unknown fields and non-declarative metadata" do
    attrs = attributes
    attrs[:intake] = attrs.fetch(:intake).merge(raw_prompt: "ignore all limits")
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /unknown fields/)

    attrs = attributes
    called = false
    attrs[:metadata] = { source_reference: -> { called = true } }
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError)
    expect(called).to be(false)
  end

  it "rejects an invalid baseline or incomplete candidate capability coverage" do
    attrs = attributes
    attrs[:baseline] = organization::Topology.new(
      id: "bad-baseline", pattern: :single,
      members: [{ agent: "generalist", role: "domain", capabilities: ["research"] }]
    )
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /baseline is missing/)

    attrs = attributes
    attrs[:candidate] = organization::Topology.new(
      id: "incomplete-team", pattern: :coordinator,
      members: [
        { agent: "coordinator", role: "coordinator", capabilities: ["synthesis"] },
        { agent: "researcher", role: "research", capabilities: ["research"] },
        { agent: "reviewer", role: "verifier", capabilities: [], independent_context: true }
      ],
      edges: candidate.edges
    )
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /candidate is missing/)
  end

  it "rejects a multi-agent candidate without exactly one coordinator" do
    attrs = attributes
    attrs[:candidate] = organization::Topology.new(
      id: "coordinatorless", pattern: :parallel,
      members: [
        { agent: "coordinator", role: "domain", capabilities: ["synthesis"] },
        { agent: "researcher", role: "research", capabilities: ["research"] },
        { agent: "reviewer", role: "verifier", capabilities: ["verification"],
          independent_context: true }
      ],
      edges: candidate.edges
    )
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /exactly one coordinator/)
  end

  it "requires candidate pattern and separation reasons to match real topology" do
    attrs = attributes
    attrs[:candidate] = organization::Topology.new(
      id: "mislabelled-single", pattern: :single,
      members: candidate.members, edges: candidate.edges
    )
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /single topology pattern/)

    attrs = attributes
    attrs[:agents] = agents.map do |agent|
      agent.fetch(:agent) == "coordinator" ?
        agent.merge(separation_reason: "context_isolation") : agent
    end
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /separation reason/)
  end

  it "binds every cross-agent dependency to a declared topology handoff" do
    attrs = attributes
    attrs[:candidate] = organization::Topology.new(
      id: "edge-free-team", pattern: :coordinator,
      members: candidate.members, edges: []
    )
    attrs[:handoffs] = []

    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /lacks a matching topology handoff/)
  end

  it "keeps verifier duties independent from effectful tools" do
    attrs = attributes
    attrs[:agents] = agents.map do |agent|
      case agent.fetch(:agent)
      when "coordinator" then agent.merge(tools: [])
      when "reviewer" then agent.merge(tools: ["publish"])
      else agent
      end
    end
    attrs[:tools] = tools.map do |tool|
      tool.fetch(:name) == "publish" ? tool.merge(owners: ["reviewer"]) : tool
    end

    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /verifier cannot own effectful/)
  end

  it "rejects effectful tools or workflow steps without an approved gate" do
    attrs = attributes
    attrs[:tools] = tools.map do |tool|
      tool.fetch(:name) == "publish" ? tool.merge(approval_gate: nil) : tool
    end
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /require an approval gate/)

    attrs = attributes
    attrs[:workflow] = workflow.map do |step|
      step.fetch(:id) == "research" ? step.merge(effect: "internal") : step
    end
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /workflow steps require/)
  end

  it "requires every risky declaration gate to be authorized by the goal" do
    attrs = attributes
    attrs[:tools] = tools.map do |tool|
      tool.fetch(:name) == "publish" ? tool.merge(approval_gate: "unapproved_gate") : tool
    end
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /not required by the goal/)

    attrs = attributes
    attrs[:tools] = tools.map do |tool|
      tool.fetch(:name) == "search" ? tool.merge(risk: "sensitive") : tool
    end
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /require an approval gate/)
  end

  it "rejects topology handoffs without exact contracts" do
    attrs = attributes
    attrs[:handoffs] = handoffs.drop(1)

    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /exactly match/)
  end

  it "rejects cyclic or unterminated workflows" do
    attrs = attributes
    attrs[:workflow] = workflow.map do |step|
      case step.fetch(:id)
      when "research" then step.merge(depends_on: ["verify"])
      when "verify" then step.merge(depends_on: ["research"])
      else step
      end
    end
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /cycle/)
  end

  it "rejects overlapping evaluation sets and budgets above workload limits" do
    attrs = attributes
    attrs[:quality] = quality.merge(holdout_set_digest: quality.fetch(:training_set_digest))
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessIntegrityError, /distinct/)

    attrs = attributes
    attrs[:budget] = budget.merge(max_cost_usd: 1.01)
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /exceeds workload/)
  end

  it "requires meaningful quality review and bounded delegation" do
    attrs = attributes
    attrs[:quality] = quality.merge(verifier: nil, external_gate: nil)
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /verifier or external gate/)

    attrs = attributes
    attrs[:quality] = quality.merge(human_review: false)
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /human review and rollback/)

    attrs = attributes
    attrs[:quality] = quality.merge(minimum_success_rate: 0)
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /must be positive/)

    attrs = attributes
    attrs[:budget] = budget.merge(max_subcalls: 0)
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /delegation budget/)
  end

  it "normalizes order without hiding semantic changes" do
    original = described_class.new(**attributes)
    reordered_attrs = attributes
    reordered_attrs[:agents] = reordered_attrs.fetch(:agents).reverse
    reordered_attrs[:tools] = reordered_attrs.fetch(:tools).reverse
    reordered_attrs[:handoffs] = reordered_attrs.fetch(:handoffs).reverse
    reordered_attrs[:workflow] = reordered_attrs.fetch(:workflow).reverse
    reordered_attrs[:launch_plan] = reordered_attrs.fetch(:launch_plan).reverse
    reordered = described_class.new(**reordered_attrs)

    expect(reordered.digest).to eq(original.digest)
    changed_attrs = attributes
    changed_attrs[:budget] = budget.merge(max_cost_usd: 0.7)
    expect(described_class.new(**changed_attrs).digest).not_to eq(original.digest)
  end

  it "rejects open output schemas and oversized serialized blueprints" do
    attrs = attributes
    attrs[:output_contract] = output_contract.merge(additionalProperties: true)
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /closed object/)

    Agentkit.config.harness.max_checkpoint_bytes = 10
    expect { described_class.new(**attributes) }
      .to raise_error(Agentkit::HarnessPersistenceError, /checkpoint byte limit/)
  end

  it "rejects malformed nested schemas and raw embedded contract metadata" do
    attrs = attributes
    attrs[:output_contract] = output_contract.merge(required: "brief_reference")
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /required fields/)

    attrs = attributes
    attrs[:workload] = organization::WorkloadContract.new(
      id: "weekly-market-brief",
      capabilities: %w[research synthesis verification],
      required_checks: %w[citations policy], max_agents: 3,
      max_cost_usd: 1.0, max_latency_ms: 10_000,
      max_human_minutes: 30, minimum_samples: 3,
      metadata: { private_prompt: "Write the complete secret prompt here" }
    )
    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /bounded identifier/)
  end

  it "rejects unsupported serialized schemas and unknown top-level fields" do
    serialized = described_class.new(**attributes).to_h
    unsupported = Marshal.load(Marshal.dump(serialized))
    unsupported["schema_version"] = 99
    expect { described_class.from_h(unsupported) }
      .to raise_error(Agentkit::HarnessExperimentError, /unsupported/)

    unknown = Marshal.load(Marshal.dump(serialized))
    unknown["runtime_authority"] = true
    expect { described_class.from_h(unknown) }
      .to raise_error(Agentkit::HarnessExperimentError, /unknown fields/)
  end

  it "rejects incomplete seven-day launch plans" do
    attrs = attributes
    attrs[:launch_plan] = launch_plan.drop(1)

    expect { described_class.new(**attrs) }
      .to raise_error(Agentkit::HarnessExperimentError, /exactly seven days/)
  end
end
