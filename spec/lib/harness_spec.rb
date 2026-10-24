# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Harness do
  before do
    Agentkit.config.memory.store = :memory
    Agentkit.config.memory.level = :log
  end

  let(:goal) do
    described_class.define(
      id: "release-42",
      objective: "ship a verifiable release",
      criteria: [
        { id: "tests", description: "test suite passes" },
        { id: "review", description: "independent review passes" }
      ],
      required_outputs: ["package"],
      max_steps: 2
    )
  end

  it "completes only after every required criterion and output has evidence" do
    progress = described_class.start(goal)
    progress.record_output("package", reference: "artifact:release.gem", value: "gem bytes")
    progress.record_evidence(
      criterion: "tests", verdict: :verified, source: "ci:123",
      summary: "green", value: "junit contents"
    )

    expect { progress.complete! }.to raise_error(Agentkit::HarnessIncomplete, /review/)

    progress.record_evidence(
      criterion: "review", verdict: :verified, source: "review:456",
      summary: "no blockers"
    )
    report = progress.complete!

    expect(report).to be_complete
    expect(progress).to be_complete
    expect(progress.to_h.to_s).not_to include("gem bytes", "junit contents")
  end

  it "reports failed and unresolved evidence without accepting it" do
    progress = described_class.start(goal)
    progress.record_evidence(criterion: "tests", verdict: :failed, source: "ci:123")
    progress.record_evidence(criterion: "review", verdict: :unresolved, summary: "pending")

    report = progress.evaluate!

    expect(report).not_to be_complete
    expect(report.failed_criteria).to eq(["tests"])
    expect(report.unresolved_criteria).to eq(["review"])
    expect(report.missing_outputs).to eq(["package"])
  end

  it "enforces the bounded step budget" do
    progress = described_class.start(goal)
    2.times { progress.advance! }

    expect { progress.advance! }
      .to raise_error(Agentkit::BudgetExceeded) { |error|
        expect(error.resource).to eq(:harness_steps)
        expect(error.limit).to eq(2)
      }
    expect(progress.status).to eq("blocked")
  end

  it "checkpoints, supersedes and resumes scoped progress" do
    context = Agentkit::Context.new(tenant_key: "acme", run_id: "run-1")
    progress = described_class.start(goal)
    first = described_class.checkpoint!(progress, context: context)
    progress.record_decision("use the signed package", source: "review:1")
    progress.next_action = "run the release review"
    second = described_class.checkpoint!(progress, context: context)

    resumed = described_class.resume(goal.id, context: context)

    expect(first.status).to eq("superseded")
    expect(first.superseded_by_id).to eq(second.id)
    expect(resumed.next_action).to eq("run the release review")
    expect(resumed.decisions.first["summary"]).to eq("use the signed package")
    expect(described_class.resume(goal.id, context: Agentkit::Context.new(tenant_key: "other"))).to be_nil
  end

  it "fails closed when checkpoint metadata is altered" do
    context = Agentkit::Context.new(tenant_key: "acme")
    record = described_class.checkpoint!(described_class.start(goal), context: context)
    record.metadata["progress"]["status"] = "completed"

    expect { described_class.resume(goal.id, context: context) }
      .to raise_error(Agentkit::HarnessIntegrityError, /digest mismatch/)
  end

  it "cannot be constructed as completed without satisfying the contract" do
    expect { Agentkit::Harness::Progress.new(goal: goal, status: "completed") }
      .to raise_error(Agentkit::HarnessIntegrityError, /does not satisfy/)
  end

  it "produces a bounded handoff context" do
    progress = described_class.start(goal)
    progress.add_issue("waiting for CI")
    progress.next_action = "poll CI"

    fragment = progress.context_fragment(max_bytes: 220)

    expect(fragment.bytesize).to be <= 220
    expect(fragment).to include("Goal Contract")
  end
end

RSpec.describe "Agent tool policy" do
  before do
    Agentkit.config.llm.adapter = :fake
    Agentkit::LLM.reset!
    Agentkit::Skill.define(:operations) do |skill|
      skill.tool(:read_file) { |path:| path }
      skill.tool(:write_file) { |path:| path }
      skill.tool(:publish) { |id:| id }
    end
  end

  it "filters tools from skills with deny taking precedence" do
    agent_class = Class.new(Agentkit::Agent) do
      uses_skills :operations
      allow_tools :read_file, :write_file
      deny_tools :write_file
    end

    agent_class.new.chat("inspect")

    expect(fake_llm.calls.last.tools.map(&:name)).to eq([:read_file])
    expect(emitted("agent.tools.filtered").last.measures[:removed]).to eq(2)
  end

  it "applies the same policy to explicitly supplied tools" do
    agent_class = Class.new(Agentkit::Agent) do
      allow_tools :read_file
    end
    explicit = Agentkit::SkillRegistry.tools_for(:operations)

    agent_class.new.chat("inspect", tools: explicit)

    expect(fake_llm.calls.last.tools.map(&:name)).to eq([:read_file])
  end

  it "fails closed for an unnamed tool under a restrictive policy" do
    agent_class = Class.new(Agentkit::Agent) do
      deny_tools :publish
    end

    expect { agent_class.new.chat("inspect", tools: [Object.new]) }
      .to raise_error(Agentkit::ConfigurationError, /unnamed tool/)
  end

  it "preserves backwards-compatible exposure without a policy" do
    agent_class = Class.new(Agentkit::Agent) do
      uses_skills :operations
    end

    agent_class.new.chat("inspect")

    expect(fake_llm.calls.last.tools.map(&:name)).to contain_exactly(:read_file, :write_file, :publish)
  end

  it "does not let a subclass accidentally widen an inherited policy" do
    parent = Class.new(Agentkit::Agent) do
      uses_skills :operations
      allow_tools :read_file
      deny_tools :publish
    end
    child = Class.new(parent) do
      allow_tools :read_file, :write_file, :publish
      deny_tools :write_file
    end

    child.new.chat("inspect")

    expect(child.tool_policy).to eq(allow: [:read_file], deny: %i[publish write_file])
    expect(fake_llm.calls.last.tools.map(&:name)).to eq([:read_file])
  end
end
